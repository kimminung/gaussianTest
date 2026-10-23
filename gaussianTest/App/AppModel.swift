import Foundation
import Observation
import simd
import UniformTypeIdentifiers

/// 라이브러리의 한 항목.
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

extension UTType {
    static let ply: UTType = UTType(filenameExtension: "ply") ?? .data
}

@Observable
@MainActor
final class AppModel {
    var scenes: [StageScene]
    var selectedSceneID: StageScene.ID?
    let player = SplatPlayer()

    var placement = StagePlacement.default
    var flipY = false
    var snapToFloor = false
    var centerHorizontally = false

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
    }

    var selectedScene: StageScene? {
        scenes.first { $0.id == selectedSceneID }
    }

    // MARK: 선택

    func select(_ scene: StageScene) async {
        selectedSceneID = scene.id
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

    func selectByID(_ id: StageScene.ID?) {
        guard let id, let scene = scenes.first(where: { $0.id == id }) else {
            selectedSceneID = nil
            player.unload()
            return
        }
        guard scene.id != selectedSceneID || player.source == nil else { return }
        Task { await select(scene) }
    }

    // MARK: 가져오기

    func importURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            importSequenceFolder(url)
        } else {
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

    func removeScene(_ scene: StageScene) {
        guard scene.kind != .sample else { return }
        scenes.removeAll { $0.id == scene.id }
        if selectedSceneID == scene.id {
            selectedSceneID = nil
            player.unload()
        }
    }
}
