import SwiftUI

/// Gracia 항목의 상세 화면. macOS 는 창 안에서 바로 재생하고, visionOS 는 Gracia 전용 몰입 공간을 연다.
struct GraciaDetailView: View {
    @Environment(AppModel.self) private var app
    let scene: GraciaScene

    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    private let speeds: [Double] = [0.5, 1, 1.5, 2]

    var body: some View {
        let gracia = app.gracia
        VStack(spacing: 12) {
            header
            licenseBanner

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.black.opacity(0.35))
                #if os(macOS)
                GraciaMacPlayerView(model: gracia)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                if gracia.status.buffering || (!gracia.status.loaded && gracia.errorMessage == nil) {
                    ProgressView(scene.source.isStream ? "스트리밍 버퍼링 중…" : "로딩 중…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                #else
                if gracia.isImmersed {
                    ContentUnavailableView(
                        "Gracia 몰입 공간에서 재생 중",
                        systemImage: "visionpro",
                        description: Text("한 손 핀치로 옮기고, 두 손 핀치로 키우거나 돌려요.")
                    )
                } else {
                    ContentUnavailableView(
                        "Gracia 렌더러로 재생",
                        systemImage: "cube.transparent",
                        description: Text("Gracia SDK 의 Metal 렌더러가 Compositor Services 로 양안 렌더링해요. 아래에서 몰입 공간을 여세요.")
                    )
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
            footer
        }
        .padding()
        .navigationTitle(scene.title)
        #if os(visionOS)
        .task(id: gracia.isImmersed) {
            guard gracia.isImmersed else { return }
            while !Task.isCancelled {
                gracia.refreshFromLink()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #endif
    }

    // MARK: 머리말

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.title).font(.title2.bold())
                Text("\(scene.kind.rawValue) · \(scene.subtitle)").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            let s = app.gracia.status
            if s.loaded {
                Label("\(Int(s.visibleSplats).formatted()) / \(Int(s.splatsBudget).formatted()) 스플랫", systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var licenseBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(GraciaCatalog.licenseNotice)
            Spacer()
            Link("CONTENT-LICENSE", destination: GraciaCatalog.licenseURL)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 컨트롤

    private var controls: some View {
        @Bindable var gracia = app.gracia
        let s = gracia.status
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    gracia.isPlaying.toggle()
                } label: {
                    Image(systemName: gracia.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .disabled(!s.isVideo)
                .accessibilityLabel(gracia.isPlaying ? "일시정지" : "재생")

                Slider(
                    value: Binding(
                        get: { s.playhead },
                        set: { gracia.seek(to: $0) }
                    ),
                    in: 0...max(s.duration, 0.001)
                )
                .disabled(!s.isVideo || s.duration <= 0)

                Text(timeLabel(s))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 110, alignment: .trailing)
            }

            HStack(spacing: 16) {
                Picker("배속", selection: $gracia.speed) {
                    ForEach(speeds, id: \.self) { v in
                        Text(v == 1 ? "1×" : String(format: "%g×", v)).tag(v)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                #if os(macOS)
                Text("드래그 궤도 · 스크롤 줌 · WASD 비행 · 0 재프레이밍")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                Spacer()

                #if os(visionOS)
                immersiveButtons
                #endif
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func timeLabel(_ s: GraciaStatus) -> String {
        guard s.isVideo else { return s.loaded ? "정지 장면" : "—" }
        if s.buffering { return "버퍼링…" }
        return String(format: "%.1fs / %.1fs", s.playhead, s.duration)
    }

    #if os(visionOS)
    @ViewBuilder
    private var immersiveButtons: some View {
        @Bindable var gracia = app.gracia
        if gracia.isImmersed {
            Picker("몰입", selection: $gracia.immersion) {
                ForEach(GraciaImmersionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Button("내 앞으로", systemImage: "scope") { gracia.recenter() }

            Button("무대 닫기", systemImage: "xmark.circle") {
                Task {
                    await dismissImmersiveSpace()
                    gracia.isImmersed = false
                }
            }
        } else {
            Button("내 방에 배치", systemImage: "cube.transparent") {
                gracia.immersion = .mixed
                Task { await openGraciaStage() }
            }
            .buttonStyle(.borderedProminent)

            Button("완전 몰입", systemImage: "visionpro") {
                gracia.immersion = .full
                Task { await openGraciaStage() }
            }
        }
    }

    private func openGraciaStage() async {
        // 몰입 공간은 하나만 열 수 있다. RealityKit 무대가 열려 있으면 먼저 닫는다.
        if app.isImmersiveOpen {
            await dismissImmersiveSpace()
        }
        switch await openImmersiveSpace(id: GraciaImmersiveSpace.id) {
        case .opened:
            app.gracia.isImmersed = true
            app.statusMessage = nil
        case .userCancelled:
            app.gracia.isImmersed = false
            app.statusMessage = "몰입 공간 열기를 취소했어요."
        case .error:
            app.gracia.isImmersed = false
            app.statusMessage = "Gracia 몰입 공간을 열 수 없어요."
        @unknown default:
            app.gracia.isImmersed = false
        }
    }
    #endif

    // MARK: 바닥글

    private var footer: some View {
        let s = app.gracia.status
        return HStack(spacing: 12) {
            Image(systemName: "cpu")
            Text("Gracia SDK · 자체 Metal 렌더러")
            if s.loaded {
                Text(String(format: "%.0f fps · GPU %.0f MB", s.fps, Double(s.gpuBytes) / 1e6)).monospacedDigit()
            }
            Spacer()
            if let message = app.gracia.errorMessage ?? app.statusMessage {
                Text(message).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// visionOS Gracia 몰입 공간 식별자.
enum GraciaImmersiveSpace {
    static let id = "gracia-stage"
}
