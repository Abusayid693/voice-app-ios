import Compression
import Foundation

/// Random-access reader over an EPUB's ZIP container.
///
/// No third-party dependency: a ZIP entry's compressed bytes are raw DEFLATE
/// (RFC 1951, no zlib header/trailer), and `Compression.framework`'s
/// `COMPRESSION_ZLIB` algorithm decodes exactly that stream through
/// `compression_decode_buffer` — confirmed against a known raw-deflate buffer
/// before this was written, since the framework's naming invites the opposite
/// assumption (zlib-wrapped, RFC 1950).
///
/// Reads the end-of-central-directory record, then the central directory
/// itself, so every entry's path and location are known up front; a path is
/// only inflated when `data(at:)` is actually called. The whole archive is
/// memory-mapped rather than loaded, since an EPUB's images (never read by
/// this importer beyond the cover) can dwarf the text that matters.
struct EPUBArchive {
    struct Entry {
        let compressedSize: Int
        let uncompressedSize: Int
        /// `false` means stored (method 0); `true` means deflated (method 8).
        /// Every other method is rejected when the central directory is read,
        /// since the only producers of a self-described method 0/8-only ZIP
        /// *are* ordinary EPUB writers — anything else is not an EPUB this
        /// reader can trust.
        let isDeflated: Bool
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entriesByPath: [String: Entry]

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entriesByPath = try Self.readCentralDirectory(data)
    }

    func contains(_ path: String) -> Bool { entriesByPath[path] != nil }

    /// Inflates one entry's content. Each call re-reads the local header
    /// rather than trusting the central directory's own copy of the name —
    /// the two are required to match, but reading the authoritative length
    /// fields at the data's actual location is one bounds check away and
    /// removes a class of corrupt-archive crashes for free.
    func data(at path: String) throws -> Data {
        guard let entry = entriesByPath[path] else {
            throw EPUBArchiveError.entryNotFound(path)
        }
        let dataStart = try localFileDataOffset(for: entry)
        let end = dataStart + entry.compressedSize
        guard end <= data.count else { throw EPUBArchiveError.truncatedArchive }
        let compressed = data.subdata(in: dataStart..<end)

        guard entry.isDeflated else { return compressed }
        return try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
    }

    // MARK: - Central directory

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    /// ZIP permits an archive comment up to this length after the EOCD
    /// record, which is why the signature search below scans backward from
    /// the end rather than assuming EOCD is the very last bytes.
    private static let maxCommentLength = 65535

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard let eocdOffset = findEndOfCentralDirectory(data) else {
            throw EPUBArchiveError.notAZipArchive
        }
        let entryCount = Int(data.readUInt16(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(data.readUInt32(at: eocdOffset + 16))
        guard centralDirectoryOffset < data.count else {
            throw EPUBArchiveError.truncatedArchive
        }

        var entries: [String: Entry] = [:]
        var cursor = centralDirectoryOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  data.readUInt32(at: cursor) == centralDirectoryHeaderSignature
            else {
                throw EPUBArchiveError.corruptCentralDirectory
            }
            let method = data.readUInt16(at: cursor + 10)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localHeaderOffset = Int(data.readUInt32(at: cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw EPUBArchiveError.corruptCentralDirectory
            }
            guard let path = String(
                data: data.subdata(in: nameStart..<(nameStart + nameLength)),
                encoding: .utf8
            ) else {
                throw EPUBArchiveError.corruptCentralDirectory
            }

            // Methods 0 (stored) and 8 (deflated) cover every EPUB-producing
            // tool in practice; anything else is rejected outright rather than
            // silently mis-decoded.
            switch method {
            case 0: entries[path] = Entry(
                    compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                    isDeflated: false, localHeaderOffset: localHeaderOffset)
            case 8: entries[path] = Entry(
                    compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                    isDeflated: true, localHeaderOffset: localHeaderOffset)
            default: throw EPUBArchiveError.unsupportedCompressionMethod(method)
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Scans backward for the EOCD signature within the last
    /// `22 + maxCommentLength` bytes, since the record is fixed-size (22
    /// bytes) plus a variable trailing comment.
    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        let recordSize = 22
        guard data.count >= recordSize else { return nil }
        let searchFloor = max(0, data.count - recordSize - maxCommentLength)
        var offset = data.count - recordSize
        while offset >= searchFloor {
            if data.readUInt32(at: offset) == endOfCentralDirectorySignature {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// The central directory's stored offset is occasionally off by a
    /// constant amount (a self-extracting prefix, or an archive that was
    /// concatenated after creation) — re-deriving the data start from the
    /// entry's own local header, rather than trusting
    /// `localHeaderOffset + 30 + nameLength + extraLength` blindly, catches
    /// the same corruption `data(at:)`'s doc comment already protects
    /// against, in the one place it would otherwise go undetected until a
    /// later, harder-to-diagnose inflate failure.
    private func localFileDataOffset(for entry: Entry) throws -> Int {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count,
              data.readUInt32(at: offset) == Self.localFileHeaderSignature
        else {
            throw EPUBArchiveError.corruptCentralDirectory
        }
        let nameLength = Int(data.readUInt16(at: offset + 26))
        let extraLength = Int(data.readUInt16(at: offset + 28))
        return offset + 30 + nameLength + extraLength
    }

    // MARK: - Inflate

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destination.deallocate() }

        let decodedCount = compressed.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destination, expectedSize, base, compressed.count, nil, COMPRESSION_ZLIB)
        }
        guard decodedCount == expectedSize else {
            throw EPUBArchiveError.inflateFailed
        }
        return Data(bytes: destination, count: decodedCount)
    }
}

enum EPUBArchiveError: LocalizedError {
    case notAZipArchive
    case corruptCentralDirectory
    case truncatedArchive
    case unsupportedCompressionMethod(UInt16)
    case inflateFailed
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "This file is not a readable EPUB archive."
        case .corruptCentralDirectory, .truncatedArchive:
            return "This EPUB's archive structure is damaged."
        case .unsupportedCompressionMethod:
            return "This EPUB uses an unsupported compression method."
        case .inflateFailed:
            return "A file inside this EPUB could not be decompressed."
        case .entryNotFound(let path):
            return "This EPUB is missing an expected file: \(path)."
        }
    }
}

/// Little-endian field reads, bounds-checked by every call site above rather
/// than here — each read happens only after its surrounding fixed-size record
/// has already been confirmed to fit.
private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[self.startIndex + offset])
            | (UInt16(self[self.startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[self.startIndex + offset])
            | (UInt32(self[self.startIndex + offset + 1]) << 8)
            | (UInt32(self[self.startIndex + offset + 2]) << 16)
            | (UInt32(self[self.startIndex + offset + 3]) << 24)
    }
}
