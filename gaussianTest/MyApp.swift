import SwiftUI

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
        ImmersiveSpace(id: ImmersiveStageView.spaceID) {
            ImmersiveStageView()
                .environment(app)
        }
        .immersionStyle(selection: immersionSelection, in: .mixed, .full)
        .upperLimbVisibility(.visible)
        #endif
    }

    #if os(visionOS)
    /// AppModel 의 Bool 을 ImmersionStyle 바인딩으로 바꿔 mixed ↔ full 전환.
    private var immersionSelection: Binding<any ImmersionStyle> {
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
    #endif
}
