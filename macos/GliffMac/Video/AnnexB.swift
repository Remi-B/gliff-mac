import Foundation

/// H.264 Annex B access units as the server sends them: start-code-delimited
/// NAL units, with SPS and PPS in-band ahead of every IDR (the server never
/// fills `extradata`). VideoToolbox wants the parameter sets apart and the
/// slices with 4-byte big-endian length prefixes instead of start codes.
///
/// Mirrors `gliff-client-core::annexb`: only NAL headers are read, never
/// slice syntax.
struct AccessUnit: Equatable {
    /// NAL unit types (ITU-T H.264 table 7-1) the decoder cares about.
    enum NALType {
        static let nonIDRSlice: UInt8 = 1
        static let idrSlice: UInt8 = 5
        static let sps: UInt8 = 7
        static let pps: UInt8 = 8
        static let accessUnitDelimiter: UInt8 = 9
    }

    enum ParseError: Error, Equatable {
        case noStartCode
        /// Bytes before the first start code: not a NAL unit.
        case leadingBytes(Int)
        /// A start code followed by nothing, or by another start code.
        case emptyUnit(at: Int)
        case forbiddenBit(at: Int)
        /// No coded slice: nothing to decode (for example a truncated frame).
        case noSlice
    }

    /// Sequence parameter sets, without start codes, in stream order.
    var sps: [Data]
    var pps: [Data]
    /// Every other NAL unit except access unit delimiters, each prefixed with
    /// its 4-byte big-endian length (AVCC with `NALUnitHeaderLength` 4).
    var sample: Data
    var nalTypes: [UInt8]
    var hasIDR: Bool { nalTypes.contains(NALType.idrSlice) }

    init(annexB stream: Data) throws {
        let units = try Self.nalUnits(stream)
        var sps: [Data] = []
        var pps: [Data] = []
        var sample = Data(capacity: stream.count + 4 * units.count)
        var slice = false
        for unit in units {
            let type = unit[unit.startIndex] & 0x1f
            switch type {
            case NALType.sps: sps.append(unit)
            case NALType.pps: pps.append(unit)
            case NALType.accessUnitDelimiter: break
            default:
                if type == NALType.nonIDRSlice || type == NALType.idrSlice { slice = true }
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
                sample.append(unit)
            }
        }
        guard slice else { throw ParseError.noSlice }
        self.sps = sps
        self.pps = pps
        self.sample = sample
        self.nalTypes = units.map { $0[$0.startIndex] & 0x1f }
    }

    /// Splits `stream` at its 3- or 4-byte start codes, like upstream.
    static func nalUnits(_ stream: Data) throws -> [Data] {
        let bytes = [UInt8](stream)
        var starts: [(at: Int, length: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i > 0 && bytes[i - 1] == 0 ? (i - 1, 4) : (i, 3))
                i += 3
            } else {
                i += 1
            }
        }
        guard let first = starts.first else { throw ParseError.noStartCode }
        guard first.at == 0 else { throw ParseError.leadingBytes(first.at) }
        var units: [Data] = []
        units.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            let begin = start.at + start.length
            let end = index + 1 < starts.count ? starts[index + 1].at : bytes.count
            guard begin < end else { throw ParseError.emptyUnit(at: begin) }
            guard bytes[begin] & 0x80 == 0 else { throw ParseError.forbiddenBit(at: begin) }
            units.append(Data(bytes[begin..<end]))
        }
        return units
    }
}
