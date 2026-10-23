import Foundation
import Observation

/// 4D 스플랫 플레이어. 시계 기준으로 목표 프레임을 계산해 드리프트 없이 재생한다.
@Observable
@MainActor
final class SplatPlayer {
    private(set) var source: (any SplatSource)?
    private(set) var currentCloud: SplatCloud?
    /// 프레임이 바뀔 때마다 1 증가. 뷰는 이 값만 관찰해 렌더러를 갱신한다.
    private(set) var revision = 0
    private(set) var frameIndex = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 마지막 프레임 디코드에 걸린 시간(ms). 성능 HUD 용.
    private(set) var lastDecodeMilliseconds: Double = 0

    var speed: Double = 1 {
        didSet { resetAnchor() }
    }
    var isLooping = true

    private var loopTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var anchorFrame = 0
    private var anchorInstant = ContinuousClock.now

    var frameCount: Int { source?.frameCount ?? 0 }
    var framesPerSecond: Double { source?.framesPerSecond ?? 30 }
    var duration: Double { frameCount > 1 ? Double(frameCount) / framesPerSecond : 0 }
    var currentTime: Double { Double(frameIndex) / framesPerSecond }
    var isAnimated: Bool { frameCount > 1 }

    // MARK: 로드

    func load(_ newSource: any SplatSource) async {
        stop()
        loadGeneration += 1
        let generation = loadGeneration
        source = newSource
        frameIndex = 0
        currentCloud = nil
        errorMessage = nil
        isLoading = true
        await present(frame: 0, generation: generation)
        if generation == loadGeneration { isLoading = false }
    }

    func unload() {
        stop()
        loadGeneration += 1
        source = nil
        currentCloud = nil
        frameIndex = 0
        revision &+= 1
    }

    // MARK: 재생 제어

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard source != nil, isAnimated, !isPlaying else { return }
        isPlaying = true
        if frameIndex >= frameCount - 1, !isLooping { frameIndex = 0 }
        resetAnchor()
        let generation = loadGeneration
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    func pause() {
        isPlaying = false
        loopTask?.cancel()
        loopTask = nil
    }

    func stop() {
        pause()
    }

    func seek(to frame: Int) {
        guard frameCount > 0 else { return }
        let clamped = min(max(frame, 0), frameCount - 1)
        anchorFrame = clamped
        anchorInstant = .now
        if !isPlaying {
            let generation = loadGeneration
            Task { await present(frame: clamped, generation: generation) }
        }
    }

    func step(by delta: Int) {
        pause()
        let n = frameCount
        guard n > 0 else { return }
        seek(to: ((frameIndex + delta) % n + n) % n)
    }

    // MARK: 내부

    private func resetAnchor() {
        anchorFrame = frameIndex
        anchorInstant = .now
    }

    private func runLoop(generation: Int) async {
        let clock = ContinuousClock()
        while !Task.isCancelled, isPlaying, generation == loadGeneration, let source {
            let n = source.frameCount
            guard n > 1 else { break }
            let elapsed = anchorInstant.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            var target = anchorFrame + Int(seconds * source.framesPerSecond * speed)
            if target >= n {
                if isLooping {
                    anchorFrame = target % n
                    anchorInstant = clock.now
                    target = anchorFrame
                } else {
                    await present(frame: n - 1, generation: generation)
                    isPlaying = false
                    break
                }
            }
            if target != frameIndex {
                await present(frame: target, generation: generation)
            }
            try? await clock.sleep(for: .milliseconds(4))
        }
    }

    private func present(frame: Int, generation: Int) async {
        guard let source else { return }
        let started = ContinuousClock.now
        do {
            let cloud = try await source.frame(at: frame)
            guard generation == loadGeneration else { return }
            let took = started.duration(to: .now)
            lastDecodeMilliseconds = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) * 1e-15
            currentCloud = cloud
            frameIndex = frame
            revision &+= 1
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }
}
