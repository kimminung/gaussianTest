import Foundation
import Observation

#if os(macOS)
import GraciaView
#endif

/// Gracia 렌더 경로의 상태. visionOS 는 `GraciaRenderLink` 로 렌더 스레드와, macOS 는 `SplatsSceneView` 와 동기화한다.
@Observable
@MainActor
final class GraciaPlayerModel {
    /// visionOS 렌더 스레드와 공유하는 유일한 객체.
    let link = GraciaRenderLink()

    private(set) var source: GraciaSceneSource?
    /// 장면을 고를 때마다 증가. macOS 뷰가 다시 로드할 시점을 안다.
    private(set) var sourceGeneration = 0

    var isImmersed = false

    var isPlaying = true {
        didSet { link.setPlaying(isPlaying) }
    }
    var speed: Double = 1 {
        didSet { link.setPlaybackSpeed(speed) }
    }
    var immersion: GraciaImmersionMode = .mixed {
        didSet { link.setImmersion(immersion) }
    }

    private(set) var status = GraciaStatus()
    var errorMessage: String?

    struct SeekRequest: Equatable {
        var id: Int
        var time: Double
    }
    private(set) var seekRequest: SeekRequest?

    init() {
        link.setImmersion(immersion)
    }

    // MARK: 동작

    func select(_ source: GraciaSceneSource) {
        self.source = source
        sourceGeneration += 1
        errorMessage = nil
        isPlaying = true
        status = GraciaStatus()
        link.setScene(source)
    }

    func clear() {
        source = nil
        sourceGeneration += 1
        status = GraciaStatus()
        link.setScene(nil)
    }

    func seek(to time: Double) {
        seekRequest = SeekRequest(id: (seekRequest?.id ?? 0) + 1, time: time)
        link.seek(to: time)
    }

    func recenter() { link.requestRecenter() }

    /// visionOS: 렌더 스레드의 최신 상태를 가져온다.
    func refreshFromLink() {
        status = link.status()
        if let message = status.errorMessage { errorMessage = message }
    }

    #if os(macOS)
    /// macOS: `SplatsSceneView.onStatus` 콜백을 공통 상태로 옮긴다.
    func applyMacStatus(_ s: SceneStatus) {
        var next = GraciaStatus()
        next.sceneName = s.sceneNames.joined(separator: ", ")
        next.loaded = !s.sceneNames.isEmpty
        next.isVideo = s.hasVideo
        next.visibleSplats = s.visibleSplats
        next.splatsBudget = s.splatsBudget
        next.fps = s.fps
        next.buffering = s.isBuffering
        next.duration = s.duration
        next.playhead = s.playhead
        next.gpuBytes = s.gpuBytes
        status = next
    }
    #endif
}
