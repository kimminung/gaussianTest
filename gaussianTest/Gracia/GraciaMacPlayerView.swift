#if os(macOS)
import AppKit
import GraciaSDK
import GraciaView
import Metal
import SwiftUI

/// macOS: Gracia 의 `SplatsSceneView`(자체 Metal 렌더러)를 SwiftUI 에 끼운다.
/// 드래그 궤도·스크롤 줌·WASD 비행은 뷰가 직접 처리하고, 재생 상태는 모델과 양방향으로 동기화한다.
struct GraciaMacPlayerView: NSViewRepresentable {
    let model: GraciaPlayerModel
    // 모델 참조만 넘기면 SwiftUI 가 updateNSView 를 건너뛸 수 있으므로, 바뀌는 값은 명시적 입력으로 받는다.
    let source: GraciaSceneSource?
    let sourceGeneration: Int
    let isPlaying: Bool
    let speed: Double
    let seekRequest: GraciaPlayerModel.SeekRequest?

    init(model: GraciaPlayerModel) {
        self.model = model
        source = model.source
        sourceGeneration = model.sourceGeneration
        isPlaying = model.isPlaying
        speed = model.speed
        seekRequest = model.seekRequest
    }

    final class Coordinator {
        var view: SplatsSceneView?
        var loadedGeneration = -1
        var appliedSeekID = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            report("Metal 장치를 찾을 수 없어요.")
            return NSView()
        }
        do {
            let view = try SplatsSceneView(device: device)
            view.acceptsDroppedFiles = false
            view.onStatus = { [model] status in
                model.applyMacStatus(status)
            }
            view.onError = { [model] error in
                model.errorMessage = "\(error)"
            }
            context.coordinator.view = view
            return view
        } catch {
            report("Gracia 렌더러를 만들 수 없어요: \(error)")
            return NSView()
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = context.coordinator.view else { return }
        let coordinator = context.coordinator

        if coordinator.loadedGeneration != sourceGeneration {
            coordinator.loadedGeneration = sourceGeneration
            if let source {
                do {
                    switch source {
                    case .file(let url):
                        try view.load(urls: [url])
                    case .stream(let url, let token):
                        try view.load(streamURL: url, token: token)
                    }
                } catch {
                    report("장면을 열 수 없어요: \(error)")
                }
            }
        }

        if view.isPlaying != isPlaying { view.isPlaying = isPlaying }
        if view.playbackSpeed != speed { view.playbackSpeed = speed }
        if let seek = seekRequest, seek.id != coordinator.appliedSeekID {
            coordinator.appliedSeekID = seek.id
            view.seek(to: seek.time)
        }
    }

    /// 뷰 업데이트 중 상태를 바꾸지 않도록 다음 런루프에 보고한다.
    private func report(_ message: String) {
        let model = model
        Task { @MainActor in model.errorMessage = message }
    }
}
#endif
