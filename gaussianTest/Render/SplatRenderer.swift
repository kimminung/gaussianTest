import Foundation
import RealityKit
import Metal
import simd

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

/// `SplatCloud` 를 RealityKit 엔티티로 그린다.
///
/// - 실기기·macOS: `GaussianSplatComponent` + 재사용하는 `LowLevelBuffer`(네이티브 경로)
/// - 시뮬레이터: SDK 에 네이티브 타입이 없으므로 색 버킷 메시 폴백
///
/// 계층: `root`(사용자 배치: 위치·크기·회전) → `content`(상하 반전·바닥 맞춤) → `splatEntity`
@MainActor
final class SplatRenderer {
    let root = Entity()
    let content = Entity()
    private let splatEntity = Entity()

    static var nativeAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private(set) var displayedCount = 0
    private(set) var lastError: String?
    /// 회전·바닥 맞춤 적용 후 content 로컬 공간의 경계상자.
    private(set) var contentBoundsMin: SIMD3<Float> = .zero
    private(set) var contentBoundsMax: SIMD3<Float> = .zero

    var flipY = false { didSet { if flipY != oldValue { applyOrientation() } } }
    var snapToFloor = false { didSet { if snapToFloor != oldValue { applyOrientation() } } }
    var centerHorizontally = false { didSet { if centerHorizontally != oldValue { applyOrientation() } } }

    private var cloudBoundsMin: SIMD3<Float> = .zero
    private var cloudBoundsMax: SIMD3<Float> = .zero

    var modeDescription: String {
        Self.nativeAvailable ? "네이티브 GaussianSplatComponent" : "폴백 메시(시뮬레이터)"
    }

    init() {
        root.name = "SplatStageRoot"
        content.name = "SplatContent"
        splatEntity.name = "Splats"
        root.addChild(content)
        content.addChild(splatEntity)
        root.components.set(InputTargetComponent())
    }

    // MARK: 표시

    func display(_ cloud: SplatCloud) {
        cloudBoundsMin = cloud.boundsMin
        cloudBoundsMax = cloud.boundsMax
        displayedCount = cloud.count
        #if targetEnvironment(simulator)
        updateFallback(cloud)
        #else
        updateNative(cloud)
        #endif
        applyOrientation()
    }

    func clear() {
        splatEntity.components.remove(ModelComponent.self)
        #if !targetEnvironment(simulator)
        splatEntity.components.remove(GaussianSplatComponent.self)
        buffer = nil
        capacityCount = 0
        #endif
        displayedCount = 0
    }

    // MARK: 방향·바닥

    private func applyOrientation() {
        let rotation = flipY
            ? simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        // 회전 후 경계상자(8꼭짓점 변환)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<8 {
            let corner = SIMD3<Float>(
                (i & 1) == 0 ? cloudBoundsMin.x : cloudBoundsMax.x,
                (i & 2) == 0 ? cloudBoundsMin.y : cloudBoundsMax.y,
                (i & 4) == 0 ? cloudBoundsMin.z : cloudBoundsMax.z
            )
            let p = rotation.act(corner)
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        if displayedCount == 0 { lo = .zero; hi = .zero }

        var offset = SIMD3<Float>.zero
        if snapToFloor { offset.y = -lo.y }
        if centerHorizontally {
            offset.x = -(lo.x + hi.x) * 0.5
            offset.z = -(lo.z + hi.z) * 0.5
        }
        splatEntity.transform = Transform(scale: .one, rotation: rotation, translation: .zero)
        content.position = offset
        contentBoundsMin = lo + offset
        contentBoundsMax = hi + offset

        // 제스처용 충돌 박스(root 공간, content 는 root 에 그대로 붙어 있음)
        let size = simd_max(contentBoundsMax - contentBoundsMin, SIMD3<Float>(repeating: 0.05))
        let center = (contentBoundsMin + contentBoundsMax) * 0.5
        root.components.set(CollisionComponent(
            shapes: [.generateBox(size: size).offsetBy(translation: center)],
            mode: .trigger
        ))
    }

    // MARK: - 네이티브 경로

    #if !targetEnvironment(simulator)
    private var buffer: LowLevelBuffer?
    private var capacityCount = 0

    private func updateNative(_ cloud: SplatCloud) {
        let stride = SplatCloud.Layout.stride
        do {
            if buffer == nil || cloud.count > capacityCount {
                let newCapacity = max(cloud.count, 1)
                let newBuffer = try LowLevelBuffer(descriptor: .init(capacity: newCapacity * stride, sizeMultiple: 16))
                buffer = newBuffer
                capacityCount = newCapacity
                write(cloud, into: newBuffer)
                try attachResource(buffer: newBuffer, count: newCapacity)
            } else if let buffer {
                write(cloud, into: buffer)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func attachResource(buffer: LowLevelBuffer, count: Int) throws {
        let stride = SplatCloud.Layout.stride
        let f = MemoryLayout<Float>.size
        func descriptor(_ format: MTLAttributeFormat, floatOffset: Int) -> GaussianSplatResource.BufferDescriptor {
            GaussianSplatResource.BufferDescriptor(buffer: buffer, format: format, stride: stride, offset: floatOffset * f)
        }
        let bufferResource = try GaussianSplatResource.BufferResource(
            count: count,
            position: descriptor(.float3, floatOffset: SplatCloud.Layout.positionOffset),
            scale: descriptor(.float3, floatOffset: SplatCloud.Layout.scaleOffset),
            rotation: descriptor(.float4, floatOffset: SplatCloud.Layout.rotationOffset),
            opacity: descriptor(.float, floatOffset: SplatCloud.Layout.opacityOffset),
            sphericalHarmonics: (descriptor(.float3, floatOffset: SplatCloud.Layout.colorOffset), .zero)
        )
        let resource = GaussianSplatResource(bufferResource)
        resource.scaleActivation = .exponential
        resource.opacityActivation = .sigmoid
        resource.sortingMode = .depth
        splatEntity.components.set(GaussianSplatComponent(resource))
    }

    /// 프레임 데이터를 버퍼에 덮어쓰고, 남는 슬롯은 보이지 않게 만든다.
    private func write(_ cloud: SplatCloud, into buffer: LowLevelBuffer) {
        let floats = SplatCloud.Layout.floatsPerSplat
        let used = cloud.count * floats
        let capacity = capacityCount
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            cloud.data.withUnsafeBufferPointer { src in
                if used > 0, let srcBase = src.baseAddress {
                    base.update(from: srcBase, count: used)
                }
            }
            if cloud.count < capacity {
                for i in cloud.count..<capacity {
                    let p = base + i * floats
                    p[0] = 0; p[1] = -1000; p[2] = 0
                    p[3] = SplatCloud.Layout.hiddenLogScale
                    p[4] = SplatCloud.Layout.hiddenLogScale
                    p[5] = SplatCloud.Layout.hiddenLogScale
                    p[6] = 1; p[7] = 0; p[8] = 0; p[9] = 0
                    p[10] = SplatCloud.Layout.hiddenOpacity
                    p[11] = 0; p[12] = 0; p[13] = 0
                }
            }
        }
    }
    #endif

    // MARK: - 폴백 경로(시뮬레이터)

    private static let fallbackMaxSplats = 8_000
    private static let bucketsPerChannel = 4
    private static var fallbackMaterials: [any Material] = {
        var mats: [any Material] = []
        let n = bucketsPerChannel
        for r in 0..<n {
            for g in 0..<n {
                for b in 0..<n {
                    let color = PlatformColor(
                        red: CGFloat((Float(r) + 0.5) / Float(n)),
                        green: CGFloat((Float(g) + 0.5) / Float(n)),
                        blue: CGFloat((Float(b) + 0.5) / Float(n)),
                        alpha: 1
                    )
                    mats.append(UnlitMaterial(color: color))
                }
            }
        }
        return mats
    }()

    private func updateFallback(_ cloud: SplatCloud) {
        let floats = SplatCloud.Layout.floatsPerSplat
        let step = max(1, cloud.count / Self.fallbackMaxSplats)
        let n = Self.bucketsPerChannel
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var faceMaterials: [UInt32] = []
        positions.reserveCapacity(min(cloud.count, Self.fallbackMaxSplats) * 6)

        // 정팔면체 면 인덱스(정점 0:+x 1:-x 2:+y 3:-y 4:+z 5:-z)
        let faces: [(UInt32, UInt32, UInt32)] = [
            (0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4),
            (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5),
        ]

        cloud.data.withUnsafeBufferPointer { buf in
            var i = 0
            while i < cloud.count {
                let base = i * floats
                let opacity = SplatCloud.sigmoid(buf[base + 10])
                if opacity >= 0.25 {
                    let p = SIMD3<Float>(buf[base], buf[base + 1], buf[base + 2])
                    let meanLog = (buf[base + 3] + buf[base + 4] + buf[base + 5]) / 3
                    let s = min(max(exp(meanLog) * 1.8, 0.004), 0.06)
                    let color = SplatCloud.color(fromSH0: SIMD3(buf[base + 11], buf[base + 12], buf[base + 13]))
                    let r = min(n - 1, Int(color.x * Float(n)))
                    let g = min(n - 1, Int(color.y * Float(n)))
                    let b = min(n - 1, Int(color.z * Float(n)))
                    let bucket = UInt32(r * n * n + g * n + b)

                    let v0 = UInt32(positions.count)
                    positions.append(p + SIMD3(s, 0, 0))
                    positions.append(p - SIMD3(s, 0, 0))
                    positions.append(p + SIMD3(0, s, 0))
                    positions.append(p - SIMD3(0, s, 0))
                    positions.append(p + SIMD3(0, 0, s))
                    positions.append(p - SIMD3(0, 0, s))
                    for (a, b2, c) in faces {
                        indices.append(v0 + a); indices.append(v0 + b2); indices.append(v0 + c)
                        faceMaterials.append(bucket)
                    }
                }
                i += step
            }
        }

        guard !positions.isEmpty else {
            splatEntity.components.remove(ModelComponent.self)
            return
        }
        var descriptor = MeshDescriptor(name: "splat-fallback")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .perFace(faceMaterials)
        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            splatEntity.components.set(ModelComponent(mesh: mesh, materials: Self.fallbackMaterials))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
