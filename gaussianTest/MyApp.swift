import SwiftUI
#if os(visionOS)
import CompositorServices
#endif

@main
struct MyApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1100, height: 720)

        #if os(visionOS)
        // 경로 1: RealityKit 네이티브 GaussianSplatComponent 무대
        ImmersiveSpace(id: ImmersiveStageView.spaceID) {
            ImmersiveStageView()
                .environment(app)
        }
        .immersionStyle(selection: stageImmersionSelection, in: .mixed, .full)
        .upperLimbVisibility(.visible)

        // 경로 2: Gracia SDK 의 Metal 렌더러를 Compositor Services 로 양안 렌더링
        ImmersiveSpace(id: GraciaImmersiveSpace.id) {
            CompositorLayer(configuration: GraciaLayerConfiguration()) { layerRenderer in
                let model = app.gracia
                let renderer = GraciaImmersiveRenderer(layerRenderer: layerRenderer, link: model.link) {
                    // 디지털 크라운 등 시스템이 닫은 경우도 여기로 온다.
                    Task { @MainActor in model.isImmersed = false }
                }
                layerRenderer.onSpatialEvent = { [gestures = renderer.gestureController] events in
                    gestures.handleSpatialEvents(events)
                }
                renderer.start()
            }
        }
        .immersionStyle(selection: graciaImmersionSelection, in: .mixed, .full)
        .upperLimbVisibility(.visible)
        #endif
    }

    #if os(visionOS)
    /// AppModel 의 Bool 을 ImmersionStyle 바인딩으로 바꿔 mixed ↔ full 전환.
    private var stageImmersionSelection: Binding<any ImmersionStyle> {
        Binding(
            get: {
                if app.wantsFullImmersion {
                    return FullImmersionStyle() as any ImmersionStyle
                }
                return MixedImmersionStyle() as any ImmersionStyle
            },
            set: { app.wantsFullImmersion = $0 is FullImmersionStyle }
        )
    }

    private var graciaImmersionSelection: Binding<any ImmersionStyle> {
        Binding(
            get: {
                if app.gracia.immersion == .full {
                    return FullImmersionStyle() as any ImmersionStyle
                }
                return MixedImmersionStyle() as any ImmersionStyle
            },
            set: { app.gracia.immersion = $0 is FullImmersionStyle ? .full : .mixed }
        )
    }
    #endif
}
