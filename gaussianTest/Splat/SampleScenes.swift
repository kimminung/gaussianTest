import Foundation
import simd

/// 번들 샘플 3종. 외부 4DGS 파일 없이도 4D 재생 경로를 확인하기 위한 프로시저럴 장면.
/// 모든 장면은 8초 주기로 완전히 반복된다(주파수를 1/8 Hz 의 배수로 제한).
nonisolated enum SampleScenes {
    static let loopSeconds: Double = 8
    static let fps: Double = 30
    static var frameCount: Int { Int(loopSeconds * fps) }

    static func makeDancer() -> ProceduralSplatSource {
        let rig = DancerRig(seed: 7)
        return ProceduralSplatSource(frameCount: frameCount, framesPerSecond: fps) { t in
            rig.frame(at: t)
        }
    }

    static func makeWaveFloor() -> ProceduralSplatSource {
        let field = WaveField(resolution: 150, size: 2.4)
        return ProceduralSplatSource(frameCount: frameCount, framesPerSecond: fps) { t in
            field.frame(at: t)
        }
    }

    static func makeGalaxy() -> ProceduralSplatSource {
        let galaxy = SpiralGalaxy(count: 22_000, seed: 3)
        return ProceduralSplatSource(frameCount: frameCount, framesPerSecond: fps) { t in
            galaxy.frame(at: t)
        }
    }
}

// MARK: - 결정적 난수

nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

// MARK: - 댄서

/// 캡슐 세그먼트로 만든 실물 크기(약 1.75 m) 인물. 팔을 흔들고 몸을 들썩이는 8초 루프.
nonisolated struct DancerRig: Sendable {
    enum Part: Int, CaseIterable {
        case head, torso, upperArmL, forearmL, upperArmR, forearmR, thighL, shinL, thighR, shinR, shoeL, shoeR
    }

    struct Seed {
        let part: Part
        let t: Float          // 세그먼트 축 방향 0...1
        let angle: Float      // 축 둘레 각
        let radial: Float     // 반지름 비율(표면 근처)
        let jitter: Float     // 색 밝기 흔들림
    }

    private let seeds: [Seed]
    private let twoPi = Float.pi * 2

    private static let countPerPart: [Part: Int] = [
        .head: 2600, .torso: 3800,
        .upperArmL: 1000, .forearmL: 900, .upperArmR: 1000, .forearmR: 900,
        .thighL: 1500, .shinL: 1200, .thighR: 1500, .shinR: 1200,
        .shoeL: 500, .shoeR: 500,
    ]

    private static let radius: [Part: Float] = [
        .head: 0.105, .torso: 0.135,
        .upperArmL: 0.05, .forearmL: 0.042, .upperArmR: 0.05, .forearmR: 0.042,
        .thighL: 0.082, .shinL: 0.06, .thighR: 0.082, .shinR: 0.06,
        .shoeL: 0.05, .shoeR: 0.05,
    ]

    private static let baseColor: [Part: SIMD3<Float>] = [
        .head: SIMD3(0.87, 0.70, 0.58),
        .torso: SIMD3(0.90, 0.32, 0.26),
        .upperArmL: SIMD3(0.90, 0.32, 0.26), .upperArmR: SIMD3(0.90, 0.32, 0.26),
        .forearmL: SIMD3(0.87, 0.70, 0.58), .forearmR: SIMD3(0.87, 0.70, 0.58),
        .thighL: SIMD3(0.22, 0.28, 0.48), .thighR: SIMD3(0.22, 0.28, 0.48),
        .shinL: SIMD3(0.22, 0.28, 0.48), .shinR: SIMD3(0.22, 0.28, 0.48),
        .shoeL: SIMD3(0.95, 0.95, 0.92), .shoeR: SIMD3(0.95, 0.95, 0.92),
    ]

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var seeds: [Seed] = []
        for part in Part.allCases {
            let n = Self.countPerPart[part] ?? 0
            for _ in 0..<n {
                seeds.append(Seed(
                    part: part,
                    t: rng.unit(),
                    angle: rng.unit() * .pi * 2,
                    radial: 0.9 + rng.unit() * 0.12,
                    jitter: (rng.unit() - 0.5) * 0.16
                ))
            }
        }
        self.seeds = seeds
    }

    /// 시각 t(초)에서의 관절 위치를 계산해 각 파트의 캡슐 양끝을 돌려준다.
    private func segments(at time: Double) -> [Part: (SIMD3<Float>, SIMD3<Float>)] {
        let t = Float(time)
        let bob = 0.035 * sin(twoPi * 2 * t)            // 2 Hz 들썩임
        let sway = 0.05 * sin(twoPi * 1 * t)            // 1 Hz 좌우 흔들림
        let twist = 0.25 * sin(twoPi * 0.5 * t)         // 0.5 Hz 몸통 비틀기

        let hip = SIMD3<Float>(sway, 0.93 + bob, 0)
        let neck = hip + SIMD3<Float>(sway * 0.4, 0.52, 0)
        let headTop = neck + SIMD3<Float>(0, 0.26, 0)
        let headBottom = neck + SIMD3<Float>(0, 0.08, 0)

        func shoulder(_ side: Float) -> SIMD3<Float> {
            neck + SIMD3<Float>(side * 0.20 * cos(twist), -0.03, side * 0.20 * sin(twist))
        }
        func arm(_ side: Float, phase: Float) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            let s = shoulder(side)
            let raise = 0.5 + 0.5 * sin(twoPi * 1 * t + phase)     // 0...1
            let lift = -0.9 + 1.7 * raise                            // 아래 → 위
            let dir = simd_normalize(SIMD3<Float>(side * 0.9, lift, 0.35 * cos(twoPi * 1 * t + phase)))
            let elbow = s + dir * 0.28
            let wave = 0.6 * sin(twoPi * 2 * t + phase)
            let foreDir = simd_normalize(dir + SIMD3<Float>(0, 0.9 * raise + 0.2, wave))
            let hand = elbow + foreDir * 0.27
            return (s, elbow, hand)
        }
        func leg(_ side: Float, phase: Float) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            let h = hip + SIMD3<Float>(side * 0.10, -0.02, 0)
            let step = 0.14 * max(0, sin(twoPi * 1 * t + phase))
            let knee = h + SIMD3<Float>(side * 0.02, -0.45 + step * 0.4, step)
            let foot = SIMD3<Float>(knee.x, 0.04, knee.z * 0.3)
            return (h, knee, foot)
        }

        let (sL, eL, hL) = arm(-1, phase: 0)
        let (sR, eR, hR) = arm(1, phase: .pi)
        let (hipL, kneeL, footL) = leg(-1, phase: 0)
        let (hipR, kneeR, footR) = leg(1, phase: .pi)

        return [
            .head: (headBottom, headTop),
            .torso: (hip, neck),
            .upperArmL: (sL, eL), .forearmL: (eL, hL),
            .upperArmR: (sR, eR), .forearmR: (eR, hR),
            .thighL: (hipL, kneeL), .shinL: (kneeL, footL),
            .thighR: (hipR, kneeR), .shinR: (kneeR, footR),
            .shoeL: (footL + SIMD3(0, 0, -0.04), footL + SIMD3(0, 0, 0.14)),
            .shoeR: (footR + SIMD3(0, 0, -0.04), footR + SIMD3(0, 0, 0.14)),
        ]
    }

    func frame(at time: Double) -> SplatCloud {
        let segs = segments(at: time)
        var builder = SplatCloudBuilder(capacity: seeds.count)
        let pulse = Float(0.5 + 0.5 * sin(2 * Double.pi * 0.25 * time))

        // 파트별 값을 한 번만 계산해 배열로(스플랫 루프 안에서 딕셔너리 조회 금지)
        struct PartFrame {
            var p0: SIMD3<Float>, p1: SIMD3<Float>
            var axis: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>
            var len: Float, radius: Float
            var color: SIMD3<Float>
        }
        let parts: [PartFrame] = Part.allCases.map { part in
            let (p0, p1) = segs[part] ?? (.zero, .zero)
            let axisVec = p1 - p0
            let len = simd_length(axisVec)
            let axis = len > 1e-5 ? axisVec / len : SIMD3<Float>(0, 1, 0)
            let helper: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let u = simd_normalize(simd_cross(axis, helper))
            let v = simd_cross(axis, u)
            return PartFrame(
                p0: p0, p1: p1, axis: axis, u: u, v: v, len: len,
                radius: Self.radius[part] ?? 0.05,
                color: Self.baseColor[part] ?? SIMD3(repeating: 0.7)
            )
        }

        for s in seeds {
            let pf = parts[s.part.rawValue]
            let p0 = pf.p0, p1 = pf.p1, axis = pf.axis, u = pf.u, v = pf.v, len = pf.len
            let r = pf.radius * s.radial

            var pos: SIMD3<Float>
            if s.part == .head {
                // 구: t 를 극각으로
                let phi = acos(1 - 2 * s.t)
                let dirv = sin(phi) * (cos(s.angle) * u + sin(s.angle) * v) + cos(phi) * axis
                pos = (p0 + p1) * 0.5 + dirv * r
            } else {
                // 캡슐: 몸통 + 반구 끝
                let capT = s.t * (len + 2 * r) - r
                let along = min(max(capT, 0), len)
                let overflow = capT - along
                let radialScale = sqrt(max(0, 1 - (overflow / r) * (overflow / r)))
                pos = p0 + axis * along + (cos(s.angle) * u + sin(s.angle) * v) * r * radialScale
                pos += axis * overflow
            }

            var color = pf.color * (1 + s.jitter)
            if s.part == .torso {
                // 셔츠에 흐르는 하이라이트 띠
                let band = 0.5 + 0.5 * sin((pos.y - 0.9) * 18 + Float(time) * 2 * .pi * 0.5)
                color = simd_mix(color, SIMD3(1.0, 0.75, 0.3), SIMD3(repeating: band * 0.35 * pulse))
            }
            color = simd_clamp(color, .zero, SIMD3(repeating: 1))

            let scale = SIMD3<Float>(0.014, 0.014, 0.007)
            builder.append(position: pos, scale: scale, opacity: 0.92, color: color)
        }
        return builder.build()
    }
}

// MARK: - 파동 바닥

/// 바닥 2.4 m × 2.4 m 격자가 물결치는 장면. 높이에 따라 청록 → 주황 그라데이션.
nonisolated struct WaveField: Sendable {
    let resolution: Int
    let size: Float

    func frame(at time: Double) -> SplatCloud {
        let t = Float(time)
        let n = resolution
        var builder = SplatCloudBuilder(capacity: n * n)
        let half = size / 2
        let step = size / Float(n - 1)
        let w1 = Float.pi * 2 * 0.5   // 0.5 Hz
        let w2 = Float.pi * 2 * 0.25  // 0.25 Hz
        let teal = SIMD3<Float>(0.15, 0.65, 0.70)
        let orange = SIMD3<Float>(1.0, 0.55, 0.20)

        for iy in 0..<n {
            for ix in 0..<n {
                let x = -half + Float(ix) * step
                let z = -half + Float(iy) * step
                let dist = sqrt(x * x + z * z)
                let ripple = 0.06 * sin(dist * 9 - t * w1 * 2)
                let swell = 0.05 * sin(x * 3 + t * w2 * 2) * cos(z * 3 - t * w2 * 2)
                let y = 0.08 + ripple + swell
                let h = min(max((y - 0.08 + 0.11) / 0.22, 0), 1)
                let color = simd_mix(teal, orange, SIMD3(repeating: h))
                let scale = SIMD3<Float>(step * 0.7, 0.004, step * 0.7)
                builder.append(position: SIMD3(x, y, z), scale: scale, opacity: 0.9, color: color)
            }
        }
        return builder.build()
    }
}

// MARK: - 별빛 나선

/// 눈높이 1.3 m 에 떠서 8초에 한 바퀴 도는 세 갈래 나선 성운.
nonisolated struct SpiralGalaxy: Sendable {
    struct Star {
        let radius: Float
        let arm: Float
        let armOffset: Float
        let height: Float
        let size: Float
        let tint: Float
        let twinkle: Float
    }

    let stars: [Star]

    init(count: Int, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var stars: [Star] = []
        stars.reserveCapacity(count)
        for _ in 0..<count {
            let r = pow(rng.unit(), 0.6) * 0.9
            stars.append(Star(
                radius: r,
                arm: Float(Int(rng.unit() * 3)),
                armOffset: (rng.unit() - 0.5) * (0.35 + r * 0.6),
                height: (rng.unit() - 0.5) * (0.08 + (0.9 - r) * 0.25),
                size: 0.004 + rng.unit() * rng.unit() * 0.02,
                tint: rng.unit(),
                twinkle: rng.unit() * .pi * 2
            ))
        }
        self.stars = stars
    }

    func frame(at time: Double) -> SplatCloud {
        let t = Float(time)
        let spin = Float.pi * 2 * t / Float(SampleScenes.loopSeconds)
        var builder = SplatCloudBuilder(capacity: stars.count)
        let blue = SIMD3<Float>(0.55, 0.70, 1.0)
        let gold = SIMD3<Float>(1.0, 0.85, 0.55)
        let white = SIMD3<Float>(repeating: 1)

        for s in stars {
            let armAngle = s.arm * (2 * .pi / 3)
            let theta = armAngle + s.radius * 4.2 + s.armOffset + spin * (1.2 - s.radius * 0.6)
            let x = cos(theta) * s.radius
            let z = sin(theta) * s.radius
            let y = 1.3 + s.height + 0.02 * sin(t * 2 * .pi * 0.5 + s.twinkle)
            var color = s.tint < 0.5 ? simd_mix(blue, white, SIMD3(repeating: s.tint * 2)) : simd_mix(white, gold, SIMD3(repeating: (s.tint - 0.5) * 2))
            let tw = 0.75 + 0.25 * sin(t * 2 * .pi * 1 + s.twinkle)
            color *= tw
            let core = max(0, 1 - s.radius / 0.25)
            color = simd_clamp(color + SIMD3(repeating: core * 0.3), .zero, SIMD3(repeating: 1))
            let scale = SIMD3<Float>(repeating: s.size)
            builder.append(position: SIMD3(x, y, z), scale: scale, opacity: 0.5 + 0.45 * tw, color: color)
        }
        return builder.build()
    }
}
