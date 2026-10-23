import SwiftUI
import UniformTypeIdentifiers

/// 라이브러리(사이드바) + 상세(RealityKit 무대 또는 Gracia 플레이어).
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selectedItem) {
                Section("샘플 (RealityKit 네이티브 스플랫)") {
                    ForEach(app.scenes.filter { $0.kind == .sample }) { scene in
                        SceneRow(title: scene.title, detail: Self.detail(for: scene))
                            .tag(LibraryItemID.stage(scene.id))
                    }
                }
                let imported = app.scenes.filter { $0.kind != .sample }
                if !imported.isEmpty {
                    Section("가져온 PLY") {
                        ForEach(imported) { scene in
                            SceneRow(title: scene.title, detail: Self.detail(for: scene))
                                .tag(LibraryItemID.stage(scene.id))
                                .contextMenu {
                                    Button("목록에서 제거", role: .destructive) { app.removeScene(scene) }
                                }
                        }
                    }
                }
                Section("Gracia 데모 (4DGS 스트리밍 · Gracia SDK)") {
                    ForEach(app.graciaScenes.filter { $0.kind == .demo }) { scene in
                        SceneRow(title: scene.title, detail: "\(scene.kind.rawValue) · \(scene.subtitle)")
                            .tag(LibraryItemID.gracia(scene.id))
                    }
                }
                let graciaFiles = app.graciaScenes.filter { $0.kind == .file }
                if !graciaFiles.isEmpty {
                    Section("가져온 .mint / .sog") {
                        ForEach(graciaFiles) { scene in
                            SceneRow(title: scene.title, detail: "\(scene.kind.rawValue) · \(scene.subtitle)")
                                .tag(LibraryItemID.gracia(scene.id))
                                .contextMenu {
                                    Button("목록에서 제거", role: .destructive) { app.removeGraciaScene(scene) }
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
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let scene = app.selectedGraciaScene {
                GraciaDetailView(scene: scene)
            } else {
                StageDetailView()
            }
        }
        .onChange(of: app.selectedItem) { _, item in
            app.selectItem(item)
        }
        .task {
            guard app.selectedItem == nil else { return }
            // DEBUG 실행 인자 `-scene N` 으로 시작 장면 지정(스크린샷 자동화용). N ≥ 샘플 수면 Gracia 데모.
            var startIndex = 0
            #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "scene"), let n = Int(raw) {
                startIndex = n
            }
            #endif
            app.selectedItem = item(atFlatIndex: startIndex) ?? app.scenes.first.map { .stage($0.id) }

            #if DEBUG
            // `-switchTo M -switchAfter S`: S초 뒤 M번 항목으로 전환(장면 교체 흐름 자동 검증용).
            if let raw = UserDefaults.standard.string(forKey: "switchTo"), let target = Int(raw) {
                let delay = UserDefaults.standard.double(forKey: "switchAfter")
                try? await Task.sleep(for: .seconds(max(delay, 1)))
                if let next = item(atFlatIndex: target) { app.selectedItem = next }
            }
            #endif
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.ply, .mint, .sog, .folder],
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

    /// 샘플 → Gracia 데모 순서로 이어지는 평면 인덱스를 라이브러리 항목으로 바꾼다.
    private func item(atFlatIndex index: Int) -> LibraryItemID? {
        if app.scenes.indices.contains(index) {
            return .stage(app.scenes[index].id)
        }
        let graciaIndex = index - app.scenes.count
        if app.graciaScenes.indices.contains(graciaIndex) {
            return .gracia(app.graciaScenes[graciaIndex].id)
        }
        return nil
    }

    private static func detail(for scene: StageScene) -> String {
        if scene.frameCount > 1 {
            "\(scene.kind.rawValue) · \(scene.frameCount)프레임 · \(Int(scene.framesPerSecond.rounded())) fps"
        } else {
            "\(scene.kind.rawValue) · 정지 장면"
        }
    }
}

private struct SceneRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// 선택된 RealityKit 장면의 미리보기와 플레이어.
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
                    description: Text("왼쪽에서 샘플이나 Gracia 데모를 고르거나, PLY·.mint 파일을 가져오세요.")
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
