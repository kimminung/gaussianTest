import SwiftUI

/// 재생·탐색·배치 컨트롤. Gracia 식 플레이어 바.
struct PlayerControlsView: View {
    @Environment(AppModel.self) private var app

    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    private let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2]

    var body: some View {
        @Bindable var app = app
        @Bindable var player = app.player

        VStack(spacing: 12) {
            // 타임라인
            HStack(spacing: 12) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .disabled(!player.isAnimated)
                .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")

                Button { player.step(by: -1) } label: { Image(systemName: "backward.frame") }
                    .disabled(!player.isAnimated)
                    .accessibilityLabel("이전 프레임")
                Button { player.step(by: 1) } label: { Image(systemName: "forward.frame") }
                    .disabled(!player.isAnimated)
                    .accessibilityLabel("다음 프레임")

                Slider(
                    value: Binding(
                        get: { Double(player.frameIndex) },
                        set: { player.seek(to: Int($0.rounded())) }
                    ),
                    in: 0...Double(max(player.frameCount - 1, 1))
                )
                .disabled(!player.isAnimated)

                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 110, alignment: .trailing)
            }

            // 옵션
            HStack(spacing: 16) {
                Picker("배속", selection: $player.speed) {
                    ForEach(speeds, id: \.self) { s in
                        Text(s == 1 ? "1×" : String(format: "%g×", s)).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Toggle("반복", isOn: $player.isLooping)
                    .toggleStyle(.button)
                Toggle("상하 반전", isOn: $app.flipY)
                    .toggleStyle(.button)
                Toggle("바닥 맞춤", isOn: $app.snapToFloor)
                    .toggleStyle(.button)
                Toggle("가운데 정렬", isOn: $app.centerHorizontally)
                    .toggleStyle(.button)

                Spacer()

                #if os(visionOS)
                immersiveButtons
                #endif
            }

            // 배치(몰입 중)
            #if os(visionOS)
            if app.isImmersiveOpen {
                HStack(spacing: 16) {
                    Text("크기")
                    Slider(value: scaleBinding, in: 0.1...4)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.2f×", app.placement.scale))
                        .font(.caption.monospacedDigit())
                        .frame(width: 50, alignment: .leading)
                    Text("높이")
                    Slider(value: heightBinding, in: -1...1.5)
                        .frame(maxWidth: 220)
                    Text(String(format: "%+.2f m", app.placement.position.y))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .leading)
                    Button("배치 초기화") { app.placement = .default }
                    Spacer()
                }
                .font(.callout)
            }
            #endif
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var timeLabel: String {
        let player = app.player
        guard player.isAnimated else { return "정지 장면" }
        return String(format: "%.1fs / %.1fs · %d/%d", player.currentTime, player.duration, player.frameIndex + 1, player.frameCount)
    }

    #if os(visionOS)
    private var scaleBinding: Binding<Float> {
        Binding(get: { app.placement.scale }, set: { app.placement.scale = $0 })
    }

    private var heightBinding: Binding<Float> {
        Binding(get: { app.placement.position.y }, set: { app.placement.position.y = $0 })
    }

    @ViewBuilder
    private var immersiveButtons: some View {
        if app.isImmersiveOpen {
            Picker("몰입", selection: Binding(
                get: { app.wantsFullImmersion },
                set: { app.wantsFullImmersion = $0 }
            )) {
                Text("내 방").tag(false)
                Text("완전 몰입").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Button("무대 닫기", systemImage: "xmark.circle") {
                Task { await dismissImmersiveSpace() }
            }
        } else {
            Button("내 방에 배치", systemImage: "cube.transparent") {
                app.wantsFullImmersion = false
                Task { await openStage() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.player.currentCloud == nil)

            Button("완전 몰입", systemImage: "visionpro") {
                app.wantsFullImmersion = true
                Task { await openStage() }
            }
            .disabled(app.player.currentCloud == nil)
        }
    }

    private func openStage() async {
        let result = await openImmersiveSpace(id: ImmersiveStageView.spaceID)
        switch result {
        case .opened:
            app.statusMessage = nil
        case .userCancelled:
            app.statusMessage = "몰입 공간 열기를 취소했어요."
        case .error:
            app.statusMessage = "몰입 공간을 열 수 없어요."
        @unknown default:
            break
        }
    }
    #endif
}
