import Foundation
import OnnxRuntimeBindings

/// Small helpers for building/reading `ORTValue` tensors from plain Swift
/// arrays — ONNX Runtime's Objective-C API takes/returns `NSMutableData`
/// with an explicit element type and shape, not typed Swift arrays.
enum MossNanoTensor {
    static func makeInt32(_ values: [Int32], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(length: values.count * MemoryLayout<Int32>.stride)!
        values.withUnsafeBytes { src in
            data.replaceBytes(in: NSRange(location: 0, length: src.count), withBytes: src.baseAddress!)
        }
        return try ORTValue(tensorData: data, elementType: .int32, shape: shape.map(NSNumber.init))
    }

    static func makeFloat(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(length: values.count * MemoryLayout<Float>.stride)!
        values.withUnsafeBytes { src in
            data.replaceBytes(in: NSRange(location: 0, length: src.count), withBytes: src.baseAddress!)
        }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map(NSNumber.init))
    }

    /// Reads an integer tensor back as `[Int]`, dispatching on the tensor's
    /// *actual* reported element type rather than assuming one width —
    /// OpenMOSS's own manifests don't document whether `should_continue`/
    /// `frame_token_ids`/`audio_lengths` are exported as int32, int64, or
    /// uint8/bool, and misreading that would silently produce garbage
    /// rather than a crash. Verify the real dtype once the models are
    /// downloaded (Netron or `onnx.load(...).graph`) if this throws.
    static func intArray(from value: ORTValue) throws -> [Int] {
        let info = try value.tensorTypeAndShapeInfo()
        let data = try value.tensorData()
        switch info.elementType {
        case .int8: return bytes(data, as: Int8.self).map(Int.init)
        case .uInt8: return bytes(data, as: UInt8.self).map(Int.init)
        case .int32: return bytes(data, as: Int32.self).map(Int.init)
        case .uInt32: return bytes(data, as: UInt32.self).map(Int.init)
        case .int64: return bytes(data, as: Int64.self).map(Int.init)
        case .uInt64: return bytes(data, as: UInt64.self).map(Int.init)
        default:
            throw MossNanoEngineError.unexpectedShape("non-integer element type \(info.elementType.rawValue)")
        }
    }

    static func floatArray(from value: ORTValue) throws -> [Float] {
        bytes(try value.tensorData(), as: Float.self)
    }

    static func shape(of value: ORTValue) throws -> [Int] {
        let info = try value.tensorTypeAndShapeInfo()
        return info.shape.map { $0.intValue }
    }

    private static func bytes<T>(_ data: NSData, as type: T.Type) -> [T] {
        let count = data.length / MemoryLayout<T>.stride
        return Array<T>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
            data.getBytes(buffer.baseAddress!, length: count * MemoryLayout<T>.stride)
            initializedCount = count
        }
    }
}
