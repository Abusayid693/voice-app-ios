import Foundation

/// Merges canonical WAV files — one `"fmt "` chunk, one `"data"` chunk, no
/// trailing chunks, exactly what FluidAudio's `AudioWAV.data(from:sampleRate:normalize:)`
/// produces for every Kokoro synthesis chunk — into a single WAV, by
/// keeping the first file's header and concatenating every file's raw PCM
/// payload under it, then patching the RIFF and `data` chunk sizes.
/// Chunk boundaries are located by walking the RIFF chunk list rather than
/// assuming a fixed 44-byte header, so an SDK change that inserts an extra
/// chunk fails loudly instead of corrupting audio silently.
enum WavConcatenator {
    enum WavError: Error {
        case emptyInput
        case malformedWAV
    }

    /// Returns the merged WAV data plus each input file's start time (in
    /// seconds) within the merged file — used to build a chapter's
    /// read-along/seek manifest without re-deriving chunk boundaries.
    static func merge(_ wavFiles: [Data]) throws -> (data: Data, chunkStarts: [TimeInterval]) {
        guard !wavFiles.isEmpty else { throw WavError.emptyInput }

        var header: Data?
        var bytesPerSecond: Double = 0
        var payloads: [Data] = []

        for wav in wavFiles {
            let (fmtRange, dataRange) = try locateFmtAndDataChunks(in: wav)
            if header == nil {
                header = wav.subdata(in: wav.startIndex..<dataRange.lowerBound)
                let fmt = wav.subdata(in: fmtRange)
                let channels = Double(readUInt16LE(fmt, at: 2))
                let sampleRate = Double(readUInt32LE(fmt, at: 4))
                let bitsPerSample = Double(readUInt16LE(fmt, at: 14))
                bytesPerSecond = sampleRate * channels * (bitsPerSample / 8)
            }
            payloads.append(wav.subdata(in: dataRange))
        }

        guard var mergedHeader = header, bytesPerSecond > 0 else { throw WavError.malformedWAV }
        // Defensive: the header's trailing 8 bytes are always the first
        // file's own "data" chunk marker + size field, since locateFmtAndDataChunks
        // found `dataRange` as the chunk immediately after them.
        guard mergedHeader.count >= 8,
            mergedHeader.suffix(8).prefix(4).elementsEqual("data".utf8)
        else { throw WavError.malformedWAV }

        var chunkStarts: [TimeInterval] = []
        var elapsedBytes = 0
        for payload in payloads {
            chunkStarts.append(TimeInterval(elapsedBytes) / bytesPerSecond)
            elapsedBytes += payload.count
        }
        let totalPCMSize = elapsedBytes

        var riffSize = UInt32(36 + totalPCMSize).littleEndian
        mergedHeader.replaceSubrange(4..<8, with: withUnsafeBytes(of: &riffSize) { Data($0) })

        var dataSize = UInt32(totalPCMSize).littleEndian
        let sizeFieldStart = mergedHeader.count - 4
        mergedHeader.replaceSubrange(
            sizeFieldStart..<mergedHeader.count, with: withUnsafeBytes(of: &dataSize) { Data($0) })

        var merged = mergedHeader
        merged.reserveCapacity(mergedHeader.count + totalPCMSize)
        for payload in payloads { merged.append(payload) }

        return (merged, chunkStarts)
    }

    private static func locateFmtAndDataChunks(in wav: Data) throws -> (
        fmt: Range<Data.Index>, data: Range<Data.Index>
    ) {
        guard wav.count >= 12,
            wav.subdata(in: wav.startIndex..<wav.startIndex + 4).elementsEqual("RIFF".utf8),
            wav.subdata(in: wav.startIndex + 8..<wav.startIndex + 12).elementsEqual("WAVE".utf8)
        else { throw WavError.malformedWAV }

        var fmtRange: Range<Data.Index>?
        var dataRange: Range<Data.Index>?
        var cursor = wav.startIndex + 12
        while cursor + 8 <= wav.endIndex {
            let idBytes = wav.subdata(in: cursor..<cursor + 4)
            let size = Int(readUInt32LE(wav, at: cursor + 4))
            let bodyStart = cursor + 8
            let bodyEnd = min(bodyStart + size, wav.endIndex)
            if idBytes.elementsEqual("fmt ".utf8) {
                fmtRange = bodyStart..<bodyEnd
            } else if idBytes.elementsEqual("data".utf8) {
                dataRange = bodyStart..<bodyEnd
            }
            // RIFF chunks are word-aligned: an odd-sized body is padded
            // one byte.
            cursor = bodyEnd + (size % 2)
        }
        guard let fmtRange, let dataRange else { throw WavError.malformedWAV }
        return (fmtRange, dataRange)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
