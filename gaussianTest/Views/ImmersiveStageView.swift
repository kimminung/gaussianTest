#if os(visionOS)
import SwiftUI
import RealityKit

/// 패스스루(mixed) 또는 완전 몰입(full) 공간에 무대를 세운다.
struct ImmersiveStageView: View {
    static let spaceID = "stage"

    @Environment(AppModel.self) private var app

    var body: some View {
        StageView(isImmersive: true)
            .onAppear { app.isImmersiveOpen = true }
            .onDisappear { app.isImmersiveOpen = false }
    }
}
#endif
