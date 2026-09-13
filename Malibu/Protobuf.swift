// Malibu is licensed under CPAL-1.0.
// Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution.

import Foundation

enum PBValue {
    case varint(UInt64)
    case bytes(Data)
}
struct PBField {
    let number: Int
    let value: PBValue
}

enum Protobuf {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var output = Data()
        repeat {
            let next = value >> 7
            output.append(UInt8(value & 0x7F) | (next == 0 ? 0 : 0x80))
            value = next
        } while value != 0
        return output
    }

    static func int(_ field: Int, _ value: UInt64) -> Data {
        var output = varint(UInt64(field << 3))
        output.append(varint(value))
        return output
    }

    static func bytes(_ field: Int, _ value: Data) -> Data {
        var output = varint(UInt64((field << 3) | 2))
        output.append(varint(UInt64(value.count)))
        output.append(value)
        return output
    }

    static func string(_ field: Int, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    static func fields(_ data: Data) throws -> [PBField] {
        var position = 0
        var result: [PBField] = []
        while position < data.count {
            let tag = try readVarint(data, position: &position)
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                result.append(PBField(number: field, value: .varint(try readVarint(data, position: &position))))
            case 1:
                guard position + 8 <= data.count else { throw MalibuError.protocolFailure("short fixed64 protobuf field") }
                position += 8
            case 2:
                let length = Int(try readVarint(data, position: &position))
                guard length >= 0, position + length <= data.count else {
                    throw MalibuError.protocolFailure("short protobuf data field")
                }
                result.append(PBField(number: field, value: .bytes(data.subdata(in: position..<(position + length)))))
                position += length
            case 5:
                guard position + 4 <= data.count else { throw MalibuError.protocolFailure("short fixed32 protobuf field") }
                position += 4
            default:
                throw MalibuError.protocolFailure("unsupported protobuf wire type \(tag & 7)")
            }
        }
        return result
    }

    static func firstBytes(_ data: Data, field: Int) throws -> Data? {
        for item in try fields(data) where item.number == field {
            if case .bytes(let value) = item.value { return value }
        }
        return nil
    }

    static func allBytes(_ data: Data, field: Int) throws -> [Data] {
        try fields(data).compactMap {
            guard $0.number == field, case .bytes(let value) = $0.value else { return nil }
            return value
        }
    }

    static func firstInt(_ data: Data, field: Int) throws -> UInt64? {
        for item in try fields(data) where item.number == field {
            if case .varint(let value) = item.value { return value }
        }
        return nil
    }

    static func firstInt32(_ data: Data, field: Int) throws -> Int? {
        guard let value = try firstInt(data, field: field) else { return nil }
        return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
    }

    private static func readVarint(_ data: Data, position: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.count, shift < 70 {
            let byte = data[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw MalibuError.protocolFailure("malformed protobuf varint")
    }
}
