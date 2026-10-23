import Foundation
import simd

/// 3D Gaussian Splatting PLY(ascii / binary_little_endian / binary_big_endian) 파서.
///
/// 표준 3DGS 속성(`x y z`, `scale_0..2`, `rot_0..3`, `opacity`, `f_dc_0..2`)을 읽고,
/// 색이 `red/green/blue` 뿐인 일반 포인트클라우드도 SH0 로 변환해 받아들인다.
/// 고차 SH(`f_rest_*`)는 M0 에서 무시한다.
nonisolated enum PLYSplatParser {
    enum ParseError: LocalizedError {
        case notPLY
        case unsupportedFormat(String)
        case unsupportedLayout(String)
        case missingPosition
        case truncated
        case noVertices

        var errorDescription: String? {
            switch self {
            case .notPLY: "PLY 파일이 아닙니다."
            case .unsupportedFormat(let f): "지원하지 않는 PLY 형식입니다: \(f)"
            case .unsupportedLayout(let why): "지원하지 않는 PLY 구조입니다: \(why)"
            case .missingPosition: "x, y, z 속성이 없습니다."
            case .truncated: "파일이 중간에 잘렸습니다."
            case .noVertices: "스플랫이 하나도 없습니다."
            }
        }
    }

    enum Encoding { case ascii, binaryLittle, binaryBig }

    enum ScalarType {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64

        init?(plyName: String) {
            switch plyName {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        var size: Int {
            switch self {
            case .int8, .uint8: 1
            case .int16, .uint16: 2
            case .int32, .uint32, .float32: 4
            case .float64: 8
            }
        }

        /// 0–1 색으로 정규화할 때 쓸 최댓값(정수형만).
        var integerMax: Float? {
            switch self {
            case .uint8: 255
            case .uint16: 65_535
            case .int8: 127
            case .int16: 32_767
            default: nil
            }
        }
    }

    struct Property {
        let name: String
        let type: ScalarType
        let offset: Int
    }

    struct Header {
        let encoding: Encoding
        let vertexCount: Int
        let properties: [Property]
        let vertexStride: Int
        let bodyOffset: Int
    }

    // MARK: - 진입점

    static func parse(_ data: Data) throws -> SplatCloud {
        let header = try parseHeader(data)
        guard header.vertexCount > 0 else { throw ParseError.noVertices }
        let mapping = try FieldMapping(properties: header.properties)
        switch header.encoding {
        case .ascii:
            return try parseASCII(data, header: header, mapping: mapping)
        case .binaryLittle, .binaryBig:
            return try parseBinary(data, header: header, mapping: mapping)
        }
    }

    // MARK: - 헤더

    static func parseHeader(_ data: Data) throws -> Header {
        guard data.count > 4, data.starts(with: Array("ply".utf8)) else { throw ParseError.notPLY }
        let marker = Array("end_header".utf8)
        guard let markerRange = data.range(of: Data(marker)) else { throw ParseError.notPLY }
        // end_header 뒤의 개행(\n 또는 \r\n)까지가 헤더.
        var bodyOffset = markerRange.upperBound
        while bodyOffset < data.count, data[bodyOffset] == UInt8(ascii: "\r") || data[bodyOffset] == UInt8(ascii: "\n") {
            bodyOffset += 1
            if data[bodyOffset - 1] == UInt8(ascii: "\n") { break }
        }
        guard let headerText = String(data: data[data.startIndex..<markerRange.lowerBound], encoding: .ascii) else {
            throw ParseError.notPLY
        }

        var encoding: Encoding?
        var vertexCount = 0
        var properties: [Property] = []
        var stride = 0
        var currentElement: String?
        var sawVertex = false

        for rawLine in headerText.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let keyword = parts.first else { continue }
            switch keyword {
            case "format":
                guard parts.count >= 2 else { throw ParseError.unsupportedFormat(String(rawLine)) }
                switch parts[1] {
                case "ascii": encoding = .ascii
                case "binary_little_endian": encoding = .binaryLittle
                case "binary_big_endian": encoding = .binaryBig
                default: throw ParseError.unsupportedFormat(parts[1])
                }
            case "element":
                guard parts.count >= 3 else { continue }
                currentElement = parts[1]
                if parts[1] == "vertex" {
                    vertexCount = Int(parts[2]) ?? 0
                    sawVertex = true
                } else if !sawVertex {
                    // vertex 보다 앞에 다른 element 가 있으면 바이너리 오프셋을 알 수 없다.
                    throw ParseError.unsupportedLayout("vertex 앞에 '\(parts[1])' element 가 있습니다")
                }
            case "property":
                guard currentElement == "vertex", parts.count >= 3 else { continue }
                if parts[1] == "list" {
                    throw ParseError.unsupportedLayout("vertex 에 list 속성이 있습니다")
                }
                guard let type = ScalarType(plyName: parts[1]) else {
                    throw ParseError.unsupportedLayout("알 수 없는 속성 타입 \(parts[1])")
                }
                properties.append(Property(name: parts[2], type: type, offset: stride))
                stride += type.size
            default:
                continue // comment, obj_info 등
            }
        }

        guard let encoding else { throw ParseError.unsupportedFormat("format 줄 없음") }
        return Header(encoding: encoding, vertexCount: vertexCount, properties: properties, vertexStride: stride, bodyOffset: bodyOffset)
    }

    // MARK: - 속성 매핑

    struct FieldMapping {
        let position: [Int]
        let scale: [Int]?
        let rotation: [Int]?
        let opacity: Int?
        let alpha: Int?
        let shDC: [Int]?
        let rgb: [Int]?
        let rgbType: ScalarType?

        init(properties: [Property]) throws {
            func index(_ name: String) -> Int? { properties.firstIndex { $0.name == name } }
            func indices(_ names: [String]) -> [Int]? {
                let found = names.compactMap(index)
                return found.count == names.count ? found : nil
            }
            guard let pos = indices(["x", "y", "z"]) else { throw ParseError.missingPosition }
            position = pos
            scale = indices(["scale_0", "scale_1", "scale_2"])
            rotation = indices(["rot_0", "rot_1", "rot_2", "rot_3"])
            opacity = index("opacity")
            alpha = index("alpha")
            shDC = indices(["f_dc_0", "f_dc_1", "f_dc_2"])
            let rgbIdx = indices(["red", "green", "blue"]) ?? indices(["r", "g", "b"])
            rgb = rgbIdx
            rgbType = rgbIdx.map { properties[$0[0]].type }
        }
    }

    // MARK: - 바이너리

    private static func parseBinary(_ data: Data, header: Header, mapping: FieldMapping) throws -> SplatCloud {
        let needed = header.bodyOffset + header.vertexCount * header.vertexStride
        guard data.count >= needed else { throw ParseError.truncated }
        let swap = header.encoding == .binaryBig
        let props = header.properties
        var builder = SplatCloudBuilder(capacity: header.vertexCount)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for v in 0..<header.vertexCount {
                let vertexBase = base + header.bodyOffset + v * header.vertexStride
                @inline(__always) func read(_ propertyIndex: Int) -> Float {
                    let p = props[propertyIndex]
                    return readScalar(vertexBase + p.offset, type: p.type, swap: swap)
                }
                let values = SplatValues(
                    position: SIMD3(read(mapping.position[0]), read(mapping.position[1]), read(mapping.position[2])),
                    logScale: mapping.scale.map { SIMD3(read($0[0]), read($0[1]), read($0[2])) },
                    rotation: mapping.rotation.map { SIMD4(read($0[0]), read($0[1]), read($0[2]), read($0[3])) },
                    opacityLogit: mapping.opacity.map(read),
                    alpha: mapping.alpha.map { read($0) },
                    shDC: mapping.shDC.map { SIMD3(read($0[0]), read($0[1]), read($0[2])) },
                    rgb: mapping.rgb.map { SIMD3(read($0[0]), read($0[1]), read($0[2])) }
                )
                values.append(to: &builder, rgbType: mapping.rgbType)
            }
        }
        return builder.build()
    }

    @inline(__always)
    private static func readScalar(_ ptr: UnsafeRawPointer, type: ScalarType, swap: Bool) -> Float {
        switch type {
        case .float32:
            var bits = ptr.loadUnaligned(as: UInt32.self)
            if swap { bits = bits.byteSwapped }
            return Float(bitPattern: bits)
        case .float64:
            var bits = ptr.loadUnaligned(as: UInt64.self)
            if swap { bits = bits.byteSwapped }
            return Float(Double(bitPattern: bits))
        case .uint8:
            return Float(ptr.load(as: UInt8.self))
        case .int8:
            return Float(ptr.load(as: Int8.self))
        case .uint16:
            var v = ptr.loadUnaligned(as: UInt16.self)
            if swap { v = v.byteSwapped }
            return Float(v)
        case .int16:
            var v = ptr.loadUnaligned(as: Int16.self)
            if swap { v = v.byteSwapped }
            return Float(v)
        case .uint32:
            var v = ptr.loadUnaligned(as: UInt32.self)
            if swap { v = v.byteSwapped }
            return Float(v)
        case .int32:
            var v = ptr.loadUnaligned(as: Int32.self)
            if swap { v = v.byteSwapped }
            return Float(v)
        }
    }

    // MARK: - ASCII

    private static func parseASCII(_ data: Data, header: Header, mapping: FieldMapping) throws -> SplatCloud {
        guard let body = String(data: data[(data.startIndex + header.bodyOffset)...], encoding: .ascii) else {
            throw ParseError.truncated
        }
        var builder = SplatCloudBuilder(capacity: header.vertexCount)
        var parsed = 0
        for line in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if parsed == header.vertexCount { break }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= header.properties.count else { continue }
            let floats = tokens.prefix(header.properties.count).map { Float($0) ?? 0 }
            func read(_ i: Int) -> Float { floats[i] }
            let values = SplatValues(
                position: SIMD3(read(mapping.position[0]), read(mapping.position[1]), read(mapping.position[2])),
                logScale: mapping.scale.map { SIMD3(read($0[0]), read($0[1]), read($0[2])) },
                rotation: mapping.rotation.map { SIMD4(read($0[0]), read($0[1]), read($0[2]), read($0[3])) },
                opacityLogit: mapping.opacity.map(read),
                alpha: mapping.alpha.map(read),
                shDC: mapping.shDC.map { SIMD3(read($0[0]), read($0[1]), read($0[2])) },
                rgb: mapping.rgb.map { SIMD3(read($0[0]), read($0[1]), read($0[2])) }
            )
            values.append(to: &builder, rgbType: mapping.rgbType)
            parsed += 1
        }
        guard parsed == header.vertexCount else { throw ParseError.truncated }
        return builder.build()
    }

    // MARK: - 공통 변환

    /// 파일에서 읽은 원시 값. 빠진 속성은 기본값으로 채운다.
    private struct SplatValues {
        var position: SIMD3<Float>
        var logScale: SIMD3<Float>?
        var rotation: SIMD4<Float>?
        var opacityLogit: Float?
        var alpha: Float?
        var shDC: SIMD3<Float>?
        var rgb: SIMD3<Float>?

        static let defaultLogScale = SIMD3<Float>(repeating: log(0.005))
        static let defaultOpacityLogit = SplatCloud.logit(0.99)

        func append(to builder: inout SplatCloudBuilder, rgbType: PLYSplatParser.ScalarType?) {
            var rot = rotation ?? SIMD4<Float>(1, 0, 0, 0)
            let len = simd_length(rot)
            rot = len > 1e-6 ? rot / len : SIMD4<Float>(1, 0, 0, 0)

            let opacity: Float
            if let opacityLogit {
                opacity = opacityLogit
            } else if let alpha {
                opacity = SplatCloud.logit(alpha / 255)
            } else {
                opacity = Self.defaultOpacityLogit
            }

            let sh: SIMD3<Float>
            if let shDC {
                sh = shDC
            } else if let rgb {
                let maxValue = rgbType?.integerMax ?? 1
                sh = SplatCloud.sh0(fromColor: rgb / maxValue)
            } else {
                sh = SplatCloud.sh0(fromColor: SIMD3<Float>(repeating: 0.7))
            }

            builder.appendRaw(
                position: position,
                logScale: logScale ?? Self.defaultLogScale,
                rotation: rot,
                opacityLogit: opacity,
                sh0: sh
            )
        }
    }
}
