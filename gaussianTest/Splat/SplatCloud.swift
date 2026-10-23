import Foundation
import simd

/// 한 프레임의 가우시안 스플랫 집합.
///
/// RealityKit `GaussianSplatResource` 가 그대로 참조할 수 있는 인터리브 레이아웃으로 저장한다.
/// 스플랫 하나 = Float 16개(64바이트):
/// 위치 3 · 스케일 3(log 공간) · 회전 4(w, x, y, z) · 불투명도 1(logit) · SH 0차 색 3 · 패딩 2
nonisolated struct SplatCloud: Sendable {
    enum Layout {
        static let floatsPerSplat = 16
        static let stride = floatsPerSplat * MemoryLayout<Float>.size
        static let positionOffset = 0
        static let scaleOffset = 3
        static let rotationOffset = 6
        static let opacityOffset = 10
        static let colorOffset = 11
        /// SH 0차 계수 ↔ 선형 색 변환 상수 (1 / (2√π)).
        static let sh0Scale: Float = 0.282_094_79
        /// 숨김 슬롯에 쓰는 값. sigmoid(-30) ≈ 0, exp(-20) ≈ 0.
        static let hiddenOpacity: Float = -30
        static let hiddenLogScale: Float = -20
    }

    let count: Int
    let data: [Float]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    init(count: Int, data: [Float]) {
        precondition(data.count >= count * Layout.floatsPerSplat, "스플랫 데이터 길이가 부족합니다")
        self.count = count
        self.data = data
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        data.withUnsafeBufferPointer { buf in
            for i in 0..<count {
                let base = i * Layout.floatsPerSplat
                let p = SIMD3<Float>(buf[base], buf[base + 1], buf[base + 2])
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        if count == 0 {
            lo = .zero
            hi = .zero
        }
        boundsMin = lo
        boundsMax = hi
    }

    static let empty = SplatCloud(count: 0, data: [])

    var center: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var extent: SIMD3<Float> { boundsMax - boundsMin }

    // MARK: 변환 도우미

    static func sh0(fromColor color: SIMD3<Float>) -> SIMD3<Float> {
        (color - 0.5) / Layout.sh0Scale
    }

    static func color(fromSH0 sh: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(sh * Layout.sh0Scale + 0.5, .zero, SIMD3<Float>(repeating: 1))
    }

    static func logit(_ value: Float) -> Float {
        let c = min(max(value, 1e-4), 1 - 1e-4)
        return log(c / (1 - c))
    }

    static func sigmoid(_ x: Float) -> Float {
        1 / (1 + exp(-x))
    }
}

/// 스플랫을 하나씩 추가해 `SplatCloud` 를 만드는 빌더. 선형 스케일/불투명도를 받아 log/logit 으로 바꿔 넣는다.
nonisolated struct SplatCloudBuilder {
    private(set) var data: [Float] = []
    private(set) var count = 0

    init(capacity: Int) {
        data.reserveCapacity(capacity * SplatCloud.Layout.floatsPerSplat)
    }

    mutating func append(
        position: SIMD3<Float>,
        scale: SIMD3<Float>,
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        opacity: Float,
        color: SIMD3<Float>
    ) {
        let safeScale = simd_max(scale, SIMD3<Float>(repeating: 1e-5))
        let sh = SplatCloud.sh0(fromColor: color)
        let q = rotation.normalized
        data.append(position.x); data.append(position.y); data.append(position.z)
        data.append(log(safeScale.x)); data.append(log(safeScale.y)); data.append(log(safeScale.z))
        data.append(q.real); data.append(q.imag.x); data.append(q.imag.y); data.append(q.imag.z)
        data.append(SplatCloud.logit(opacity))
        data.append(sh.x); data.append(sh.y); data.append(sh.z)
        data.append(0); data.append(0)
        count += 1
    }

    /// 이미 log/logit 공간인 원시 값을 그대로 넣는다(PLY 파서용).
    mutating func appendRaw(
        position: SIMD3<Float>,
        logScale: SIMD3<Float>,
        rotation: SIMD4<Float>,
        opacityLogit: Float,
        sh0: SIMD3<Float>
    ) {
        data.append(position.x); data.append(position.y); data.append(position.z)
        data.append(logScale.x); data.append(logScale.y); data.append(logScale.z)
        data.append(rotation.x); data.append(rotation.y); data.append(rotation.z); data.append(rotation.w)
        data.append(opacityLogit)
        data.append(sh0.x); data.append(sh0.y); data.append(sh0.z)
        data.append(0); data.append(0)
        count += 1
    }

    func build() -> SplatCloud {
        SplatCloud(count: count, data: data)
    }
}
