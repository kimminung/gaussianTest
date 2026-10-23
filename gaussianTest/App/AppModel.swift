import Foundation
import Observation
import simd
import UniformTypeIdentifiers

/// 라이브러리의 RealityKit 경로 항목.
struct StageScene: Identifiable {
    enum Kind: String {
        case sample = "샘플"
        case file = "PLY 파일"
        case sequence = "PLY 시퀀스"
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let kind: Kind
    let source: any SplatSource
    /// 파일은 COLMAP 계열(Y 아래)이 많아 기본 반전, 샘플은 그대로.
    let defaultFlipY: Bool
    let defaultSnapToFloor: Bool

    var frameCount: Int { source.frameCount }
    var framesPerSecond: Double { source.framesPerSecond }
}

/// 몰입 공간에서의 배치 상태.
struct StagePlacement: Equatable {
    var position = SIMD3<Float>(0, 0, -1.5)
    var scale: Float = 1
    var yaw: Float = 0

    static let `default` = StagePlacement()
}

/// 사이드바 선택. RealityKit 경로(StageScene)와 Gracia 경로(GraciaScene)를 한 목록에서 고른다.
enum LibraryItemID: Hashable {
    case stage(UUID)
    case gracia(UUID)
}

extension UTType {
    static let ply: UTType = UTType(filenameExtension: "ply") ?? .data
    static let mint: UTType = UTType(filenameExtension: "mint") ?? .data
    static let sog: UTType = UTType(filenameExtension: "sog") ?? .data
}

@Observable
@MainActor
final class AppModel {
    var scenes: [StageScene]
    var graciaScenes: [GraciaScene]
    var selectedItem: LibraryItemID?
    /// 실제로 플레이어에 로드된 항목. `selectedItem` 은 바인딩이 먼저 바꾸므로 중복 로드 판단에 쓰면 안 된다.
    private var loadedItem: LibraryItemID?

    let player = SplatPlayer()
    let gracia = GraciaPlayerModel()

    var placement = StagePlacement.default
    var flipY = false
    var snapToFloor = false
    var centerHorizontally = false

    /// RealityKit 무대 몰입 공간이 열려 있는지.
    var isImmersiveOpen = false
    var wantsFullImmersion = false
    var statusMessage: String?

    init() {
        scenes = [
            StageScene(
                title: "스트리트 댄서",
                subtitle: "실물 크기 프로시저럴 인물 · 8초 루프",
                kind: .sample,
                source: SampleScenes.makeDancer(),
                defaultFlipY: false,
                defaultSnapToFloor: false
            ),
            StageScene(
                title: "파동 바닥",
                subtitle: "2.4 m 격자 물결 · 22,500 스플랫",
                kind: .sample,
                source: SampleScenes.makeWaveFloor(),
                defaultFlipY: false,
                defaultSnapToFloor: false
            ),
            StageScene(
                title: "별빛 나선",
                subtitle: "눈높이에 도는 나선 성운 · 22,000 스플랫",
                kind: .sample,
                source: SampleScenes.makeGalaxy(),
                defaultFlipY: false,
                defaultSnapToFloor: false
            ),
        ]
        graciaScenes = GraciaCatalog.makeDemoScenes()
    }

    var selectedScene: StageScene? {
        guard case .stage(let id) = selectedItem else { return nil }
        return scenes.first { $0.id == id }
    }

    var selectedGraciaScene: GraciaScene? {
        guard case .gracia(let id) = selectedItem else { return nil }
        return graciaScenes.first { $0.id == id }
    }

    // MARK: 선택

    func select(_ scene: StageScene) async {
        selectedItem = .stage(scene.id)
        loadedItem = .stage(scene.id)
        flipY = scene.defaultFlipY
        snapToFloor = scene.defaultSnapToFloor
        centerHorizontally = scene.kind != .sample
        statusMessage = nil
        await player.load(scene.source)
        if let error = player.errorMessage {
            statusMessage = error
        } else if player.isAnimated {
            player.play()
        }
    }

    func select(_ scene: GraciaScene) {
        selectedItem = .gracia(scene.id)
        loadedItem = .gracia(scene.id)
        statusMessage = nil
        player.pause()
        gracia.select(scene.source)
    }

    func selectItem(_ item: LibraryItemID?) {
        guard item != loadedItem else { return }
        switch item {
        case .stage(let id):
            guard let scene = scenes.first(where: { $0.id == id }) else { return }
            Task { await select(scene) }
        case .gracia(let id):
            guard let scene = graciaScenes.first(where: { $0.id == id }) else { return }
            select(scene)
        case nil:
            selectedItem = nil
            loadedItem = nil
            player.unload()
            gracia.clear()
        }
    }

    // MARK: 가져오기

    func importURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            importSequenceFolder(url)
            return
        }
        switch url.pathExtension.lowercased() {
        case "mint", "sog":
            importGraciaFile(url)
        default:
            importPLYFile(url)
        }
    }

    func importPLYFile(_ url: URL) {
        let scene = StageScene(
            title: url.deletingPathExtension().lastPathComponent,
            subtitle: "3DGS PLY · 정지 장면",
            kind: .file,
            source: PLYFileSource(url: url),
            defaultFlipY: true,
            defaultSnapToFloor: true
        )
        scenes.append(scene)
        statusMessage = "불러왔어요: \(scene.title)"
        Task { await select(scene) }
    }

    func importSequenceFolder(_ url: URL) {
        do {
            let source = try PLYSequenceSource(folderURL: url)
            let scene = StageScene(
                title: url.lastPathComponent,
                subtitle: "PLY 시퀀스 · \(source.frameCount)프레임 · \(Int(source.framesPerSecond.rounded())) fps",
                kind: .sequence,
                source: source,
                defaultFlipY: source.defaultFlipY,
                defaultSnapToFloor: true
            )
            scenes.append(scene)
            statusMessage = "불러왔어요: \(scene.title)"
            Task { await select(scene) }
        } catch {
            statusMessage = "시퀀스를 열 수 없어요: \(error.localizedDescription)"
        }
    }

    /// `.mint`/`.sog` 는 Gracia 렌더 경로로. 렌더 스레드가 나중에 읽도록 컨테이너로 복사한다.
    func importGraciaFile(_ url: URL) {
        do {
            let copy = try GraciaCatalog.copyIntoContainer(url)
            let scene = GraciaScene(
                title: url.deletingPathExtension().lastPathComponent,
                subtitle: url.pathExtension.lowercased() == "mint" ? "4DGS 볼류메트릭 영상" : "정지 장면",
                kind: .file,
                source: .file(copy)
            )
            graciaScenes.append(scene)
            statusMessage = "불러왔어요: \(scene.title)"
            select(scene)
        } catch {
            statusMessage = "파일을 가져올 수 없어요: \(error.localizedDescription)"
        }
    }

    func removeScene(_ scene: StageScene) {
        guard scene.kind != .sample else { return }
        scenes.removeAll { $0.id == scene.id }
        if case .stage(let id) = selectedItem, id == scene.id {
            selectedItem = nil
            loadedItem = nil
            player.unload()
        }
    }

    func removeGraciaScene(_ scene: GraciaScene) {
        guard scene.kind == .file else { return }
        graciaScenes.removeAll { $0.id == scene.id }
        if case .gracia(let id) = selectedItem, id == scene.id {
            selectedItem = nil
            loadedItem = nil
            gracia.clear()
        }
    }
}
