import SwiftUI
import UniformTypeIdentifiers

/// 라이브러리(사이드바) + 무대 상세(미리보기·플레이어).
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selectedSceneID) {
                Section("샘플") {
                    ForEach(app.scenes.filter { $0.kind == .sample }) { scene in
                        SceneRow(scene: scene).tag(scene.id)
                    }
                }
                let imported = app.scenes.filter { $0.kind != .sample }
                if !imported.isEmpty {
                    Section("가져온 항목") {
                        ForEach(imported) { scene in
                            SceneRow(scene: scene)
                                .tag(scene.id)
                                .contextMenu {
                                    Button("목록에서 제거", role: .destructive) { app.removeScene(scene) }
                                }
                        }
                    }
                }
            }
            .navigationTitle("무대")
            .toolbar {
                ToolbarItem {
                    Button("가져오기", systemImage: "square.and.arrow.down") { showImporter = true }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            StageDetailView()
        }
        .onChange(of: app.selectedSceneID) { _, id in
            app.selectByID(id)
        }
        .task {
            guard app.selectedSceneID == nil else { return }
            // DEBUG 실행 인자 `-scene N` 으로 시작 장면 지정(스크린샷 자동화용)
            var startIndex = 0
            #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "scene"), let n = Int(raw) {
                startIndex = n
            }
            #endif
            if app.scenes.indices.contains(startIndex) {
                app.selectedSceneID = app.scenes[startIndex].id
            } else if let first = app.scenes.first {
                app.selectedSceneID = first.id
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.ply, .folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { app.importURL(url) }
            case .failure(let error):
                app.statusMessage = error.localizedDescription
            }
        }
    }
}

private struct SceneRow: View {
    let scene: StageScene

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scene.title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if scene.frameCount > 1 {
            "\(scene.kind.rawValue) · \(scene.frameCount)프레임 · \(Int(scene.framesPerSecond.rounded())) fps"
        } else {
            "\(scene.kind.rawValue) · 정지 장면"
        }
    }
}

/// 선택된 장면의 미리보기와 플레이어.
struct StageDetailView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            if let scene = app.selectedScene {
                header(scene)
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.black.opacity(0.35))
                    if app.isImmersiveOpen {
                        ContentUnavailableView(
                            "몰입 공간에서 재생 중",
                            systemImage: "visionpro",
                            description: Text("무대를 닫으면 이 창에서 다시 미리보기가 보여요.")
                        )
                    } else if app.player.isLoading && app.player.currentCloud == nil {
                        ProgressView("디코딩 중…")
                    } else {
                        StageView(isImmersive: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PlayerControlsView()
                footer
            } else {
                ContentUnavailableView(
                    "장면을 선택하세요",
                    systemImage: "cube.transparent",
                    description: Text("왼쪽에서 샘플을 고르거나 PLY 파일·시퀀스 폴더를 가져오세요.")
                )
            }
        }
        .padding()
        .navigationTitle(app.selectedScene?.title ?? "무대")
    }

    private func header(_ scene: StageScene) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.title).font(.title2.bold())
                Text(scene.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let count = app.player.currentCloud?.count {
                Label("\(count.formatted()) 스플랫", systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: SplatRenderer.nativeAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(SplatRenderer.nativeAvailable ? .green : .orange)
            Text(SplatRenderer.nativeAvailable ? "네이티브 GaussianSplatComponent" : "폴백 메시 — 시뮬레이터에는 네이티브 스플랫 API 가 없어요")
            Text(String(format: "디코드 %.1f ms", app.player.lastDecodeMilliseconds))
                .monospacedDigit()
            Spacer()
            if let message = app.statusMessage ?? app.player.errorMessage {
                Text(message).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
