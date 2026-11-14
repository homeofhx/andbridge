import Foundation

enum MTPOperation {
    static let getStorageIDs: UInt16 = 0x1004
    static let getStorageInfo: UInt16 = 0x1005
    static let getObjectHandles: UInt16 = 0x1007
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    static let deleteObject: UInt16 = 0x100B
    static let sendObjectInfo: UInt16 = 0x100C
    static let sendObject: UInt16 = 0x100D
    static let moveObject: UInt16 = 0x1019
    static let copyObject: UInt16 = 0x101A
    static let getPartialObject: UInt16 = 0x101B
    static let getObjectPropValue: UInt16 = 0x9803

    // MARK: - Android direct file I/O extensions
    static let getPartialObject64: UInt16 = 0x95C1
    static let sendPartialObject: UInt16 = 0x95C2
    static let truncateObject: UInt16 = 0x95C3
    static let beginEditObject: UInt16 = 0x95C4
    static let endEditObject: UInt16 = 0x95C5
}

enum MTPObjectProperty {
    static let objectSize: UInt32 = 0xDC04
}

struct MTPStorageInfo {
    let name: String
    let isReadOnly: Bool
}

struct MTPObjectInfo {
    let storageID: UInt32
    let format: UInt16
    let protectionStatus: UInt16
    let compressedSize: UInt32
    let associationType: UInt16
    let filename: String
    let modifiedAt: Date?

    var isFolder: Bool { format == 0x3001 || associationType == 0x0001 }
}

enum MTPCodec {
    static func command(operationCode: UInt16, transactionID: UInt32, parameters: [UInt32]) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(12 + parameters.count * 4))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(operationCode)
        data.appendLittleEndian(transactionID)
        for parameter in parameters { data.appendLittleEndian(parameter) }
        return data
    }

    static func containerType(of data: Data) -> UInt16? {
        guard data.count >= 6 else { return nil }
        return data.littleEndianUInt16(at: 4)
    }

    static func operationCode(from data: Data) -> UInt16? {
        guard data.count >= 8 else { return nil }
        return data.littleEndianUInt16(at: 6)
    }

    static func responseCode(from data: Data) -> UInt16? {
        guard data.count >= 8, containerType(of: data) == 3 else { return nil }
        return data.littleEndianUInt16(at: 6)
    }

    static func responseParameters(from data: Data) -> [UInt32] {
        guard data.count >= 12, containerType(of: data) == 3 else { return [] }
        let declaredLength = min(Int(data.littleEndianUInt32(at: 0)), data.count)
        guard declaredLength >= 12 else { return [] }
        return stride(from: 12, to: declaredLength - 3, by: 4).map { data.littleEndianUInt32(at: $0) }
    }

    static func payload(from data: Data) -> Data {
        guard data.count >= 12,
            containerType(of: data) == 2
        else { return data }
        let declaredLength = Int(data.littleEndianUInt32(at: 0))
        guard declaredLength >= 12, declaredLength <= data.count else { return data }
        return data.subdata(in: 12..<declaredLength)
    }

    static func validatedPayload(from data: Data, operationCode: UInt16) throws -> Data {
        // ImageCaptureCore normally returns a raw dataset, but some devices return the complete MTP data container.
        // Raw file/data bytes can coincidentally contain 0x0002 at the container-type offset, so only unwrap a container
        // when both its type and operation code identify this command.
        guard containerType(of: data) == 2,
            self.operationCode(from: data) == operationCode
        else { return data }
        guard data.count >= 12 else { throw MTPDecodingError.invalidDataset }
        let declaredLength = Int(data.littleEndianUInt32(at: 0))
        guard declaredLength >= 12, declaredLength <= data.count else { throw MTPDecodingError.invalidDataset }
        return data.subdata(in: 12..<declaredLength)
    }

    static func storageIDs(from data: Data) throws -> [UInt32] {
        var reader = MTPDataReader(data: payload(from: data))
        return try reader.readUInt32Array()
    }

    static func objectHandles(from data: Data) throws -> [UInt32] {
        var reader = MTPDataReader(data: payload(from: data))
        return try reader.readUInt32Array()
    }

    static func storageInfo(from data: Data, fallbackName: String) throws -> MTPStorageInfo {
        var reader = MTPDataReader(data: payload(from: data))
        _ = try reader.readUInt16()   // Storage type
        _ = try reader.readUInt16()   // Filesystem type
        let accessCapability = try reader.readUInt16()
        _ = try reader.readUInt64()   // Maximum capacity
        _ = try reader.readUInt64()   // Free space in bytes
        _ = try reader.readUInt32()   // Free space in images
        let description = try reader.readPTPString()
        let volumeLabel = try reader.readPTPString()
        let name = [description, volumeLabel].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallbackName
        return MTPStorageInfo(name: name, isReadOnly: accessCapability != 0)
    }

    static func objectInfo(from data: Data) throws -> MTPObjectInfo {
        var reader = MTPDataReader(data: payload(from: data))
        let storageID = try reader.readUInt32()
        let format = try reader.readUInt16()
        let protectionStatus = try reader.readUInt16()
        let compressedSize = try reader.readUInt32()
        _ = try reader.readUInt16()   // Thumbnail format
        _ = try reader.readUInt32()   // Thumbnail size
        _ = try reader.readUInt32()   // Thumbnail width
        _ = try reader.readUInt32()   // Thumbnail height
        _ = try reader.readUInt32()   // Image width
        _ = try reader.readUInt32()   // Image height
        _ = try reader.readUInt32()   // Image bit depth
        _ = try reader.readUInt32()   // Parent object handle
        let associationType = try reader.readUInt16()
        _ = try reader.readUInt32()   // Association description
        _ = try reader.readUInt32()   // Sequence number
        let filename = try reader.readPTPString()
        _ = try reader.readPTPString()   // Capture date
        let modificationDate = try reader.readPTPString()

        return MTPObjectInfo(storageID: storageID,
                             format: format,
                             protectionStatus: protectionStatus,
                             compressedSize: compressedSize,
                             associationType: associationType,
                             filename: filename,
                             modifiedAt: parseDate(modificationDate))
    }

    static func objectInfoDataset(storageID: UInt32,
                                  parentHandle: UInt32,
                                  name: String,
                                  isFolder: Bool,
                                  size: UInt64,
                                  modifiedAt: Date?) -> Data {
        var data = Data()
        data.appendLittleEndian(storageID)
        data.appendLittleEndian(isFolder ? UInt16(0x3001) : UInt16(0x3000))
        data.appendLittleEndian(UInt16(0))   // Protection status
        data.appendLittleEndian(size >= UInt64(UInt32.max) ? UInt32.max : UInt32(size))
        data.appendLittleEndian(UInt16(0))   // Thumbnail format
        data.appendLittleEndian(UInt32(0))   // Thumbnail size
        data.appendLittleEndian(UInt32(0))   // Thumbnail width
        data.appendLittleEndian(UInt32(0))   // Thumbnail height
        data.appendLittleEndian(UInt32(0))   // Image width
        data.appendLittleEndian(UInt32(0))   // Image height
        data.appendLittleEndian(UInt32(0))   // Image bit depth
        data.appendLittleEndian(parentHandle)
        data.appendLittleEndian(isFolder ? UInt16(1) : UInt16(0))   // Generic folder association
        data.appendLittleEndian(UInt32(0))   // Association description
        data.appendLittleEndian(UInt32(0))   // Sequence number
        data.appendPTPString(name)
        data.appendPTPString("")   // Capture date
        data.appendPTPString(modifiedAt.map(dateFormatter.string(from:)) ?? "")
        data.appendPTPString("")   // Keywords
        return data
    }

    static func objectSize(from data: Data) throws -> UInt64 {
        var reader = MTPDataReader(data: payload(from: data))
        return try reader.readUInt64()
    }

    private static func parseDate(_ value: String) -> Date? {
        guard value.count >= 15 else { return nil }
        return dateFormatter.date(from: String(value.prefix(15)))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()
}

private struct MTPDataReader {
    let data: Data
    var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return data.littleEndianUInt16(at: offset)
    }

    mutating func readUInt32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return data.littleEndianUInt32(at: offset)
    }

    mutating func readUInt64() throws -> UInt64 {
        let low = UInt64(try readUInt32())
        let high = UInt64(try readUInt32())
        return low | (high << 32)
    }

    mutating func readUInt32Array() throws -> [UInt32] {
        let count = Int(try readUInt32())
        guard count <= (data.count - offset) / 4 else { throw MTPDecodingError.invalidDataset }
        return try (0..<count).map { _ in try readUInt32() }
    }

    mutating func readPTPString() throws -> String {
        let codeUnitCount = Int(try readUInt8())
        guard codeUnitCount > 0 else { return "" }
        let byteCount = codeUnitCount * 2
        try require(byteCount)
        let stringByteCount = max(0, byteCount - 2)
        let stringData = data.subdata(in: offset..<(offset + stringByteCount))
        offset += byteCount
        return String(data: stringData, encoding: .utf16LittleEndian) ?? ""
    }

    private func require(_ count: Int) throws {
        guard count >= 0, offset >= 0, offset + count <= data.count else { throw MTPDecodingError.invalidDataset }
    }
}

enum MTPDecodingError: LocalizedError {
    case invalidDataset

    var errorDescription: String? { "The Android device returned malformed file information." }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendPTPString(_ value: String) {
        let codeUnits = Array(value.utf16.prefix(254))
        guard !codeUnits.isEmpty else {
            append(0)
            return
        }
        append(UInt8(codeUnits.count + 1))
        for codeUnit in codeUnits { appendLittleEndian(codeUnit) }
        appendLittleEndian(UInt16(0))
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
