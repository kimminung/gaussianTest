import SwiftUI
import RealityKit
import simd

/// 스플랫 무대를 그리는 RealityView. 창 미리보기와 몰입 공간이 같은 뷰를 쓴다.
struct StageView: View {
    @Environment(AppModel.self) private var app
    let isImmersive: Bool

    @State private var renderer = SplatRenderer()
    @State private var dragStartPosition: SIMD3<Float>?
    @State private var magnifyStartScale: Float?

    /// 창 미리보기에서 장면의 최대 변 길이를 맞출 크기(미터).
    #if os(visionOS)
    private let previewFitSize: Float = 0.42
    #else
    private let previewFitSize: Float = 0.8
    #endif

    var body: some View {
        #if os(visionOS)
        stage
            .gesture(dragGesture)
            .gesture(magnifyGesture)
        #else
        stage
        #endif
    }

    private var stage: some View {
        RealityView { content in
            content.add(renderer.root)
            #if !os(visionOS)
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 40
            // 살짝 위에서 내려다봐야 바닥형 장면(파동 바닥·나선)이 납작하게 보이지 않는다.
            camera.position = SIMD3<Float>(0, 0.55, 1.45)
            camera.look(at: .zero, from: camera.position, relativeTo: nil)
            content.add(camera)
            #endif
            syncRenderer()
            applyPlacement()
        } update: { _ in
            // 상태 변경은 onChange 에서 처리
        }
        .onChange(of: app.player.revision) { _, _ in
            syncRenderer()
            applyPlacement()
        }
        .onChange(of: app.flipY) { _, value in
            renderer.flipY = value
            applyPlacement()
        }
        .onChange(of: app.snapToFloor) { _, value in
            renderer.snapToFloor = value
            applyPlacement()
        }
        .onChange(of: app.centerHorizontally) { _, value in
            renderer.centerHorizontally = value
            applyPlacement()
        }
        .onChange(of: app.placement) { _, _ in
            applyPlacement()
        }
    }

    // MARK: 동기화

    private func syncRenderer() {
        renderer.flipY = app.flipY
        renderer.snapToFloor = app.snapToFloor
        renderer.centerHorizontally = app.centerHorizontally
        if let cloud = app.player.currentCloud {
            renderer.display(cloud)
        } else {
            renderer.clear()
        }
    }

    private func applyPlacement() {
        let root = renderer.root
        if isImmersive {
            root.position = app.placement.position
            root.scale = SIMD3<Float>(repeating: app.placement.scale)
            root.orientation = simd_quatf(angle: app.placement.yaw, axis: SIMD3<Float>(0, 1, 0))
        } else {
            // 창 안에 들어오도록 축소하고 가운데 정렬
            let lo = renderer.contentBoundsMin
            let hi = renderer.contentBoundsMax
            let extent = hi - lo
            let maxExtent = max(extent.x, max(extent.y, extent.z))
            let s = maxExtent > 1e-4 ? previewFitSize / maxExtent : 1
            let center = (lo + hi) * 0.5
            root.scale = SIMD3<Float>(repeating: s)
            root.orientation = simd_quatf(angle: app.placement.yaw, axis: SIMD3<Float>(0, 1, 0))
            root.position = -(root.orientation.act(center)) * s
        }
    }

    // MARK: 제스처 (visionOS 전용 3D 좌표 API)

    #if os(visionOS)
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToEntity(renderer.root)
            .onChanged { value in
                guard isImmersive else { return }
                if dragStartPosition == nil {
                    dragStartPosition = renderer.root.position
                }
                let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                let now = value.convert(value.location3D, from: .local, to: .scene)
                let delta = now - start
                var next = (dragStartPosition ?? renderer.root.position) + SIMD3<Float>(delta.x, 0, delta.z)
                next.y = app.placement.position.y
                renderer.root.position = next
            }
            .onEnded { _ in
                guard isImmersive else { return }
                app.placement.position = renderer.root.position
                dragStartPosition = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToEntity(renderer.root)
            .onChanged { value in
                guard isImmersive else { return }
                if magnifyStartScale == nil {
                    magnifyStartScale = app.placement.scale
                }
                let base = magnifyStartScale ?? 1
                let next = min(max(base * Float(value.magnification), 0.1), 4)
                renderer.root.scale = SIMD3<Float>(repeating: next)
            }
            .onEnded { _ in
                guard isImmersive else { return }
                app.placement.scale = renderer.root.scale.x
                magnifyStartScale = nil
            }
    }
    #endif
}
