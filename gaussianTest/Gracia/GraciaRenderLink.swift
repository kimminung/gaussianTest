//
//  메인 액터(SwiftUI 창)와 Compositor Services 렌더 스레드 사이의 잠금 보호 우편함.
//  gracia-labs/apple-sdk 의 visionOS 데모(MIT, © 2026 Gracia Labs and contributors) `RenderLink.swift` 를
//  무대(Mudae) 에 맞게 포팅: 장면 출처를 URL 대신 `GraciaSceneSource`(파일/스트림)로 받는다.
//

import Foundation

/// 몰입 합성 방식. `.full` 은 패스스루를 덮고(장면 안으로), `.mixed` 는 패스스루 위에 띄운다(내 방).
/// 렌더 차이는 클리어 색의 알파뿐이다. `.progressive` 는 이 렌더러의 `encodePresent` 경로가 지원하지 않는다.
nonisolated enum GraciaImmersionMode: String, Sendable, CaseIterable, Identifiable {
    case mixed, full
    var id: String { rawValue }

    var isPassthrough: Bool { self != .full }

    var label: String {
        switch self {
        case .mixed: "내 방"
        case .full: "완전 몰입"
        }
    }
}

/// 렌더 스레드(또는 macOS 뷰)가 HUD 용으로 발행하는 상태.
nonisolated struct GraciaStatus: Sendable, Equatable {
    var sceneName: String = ""
    var loaded = false
    var isVideo = false
    var visibleSplats: UInt32 = 0
    var splatsBudget: UInt32 = 0
    var fps: Double = 0
    var buffering = false
    var duration: Double = 0
    var playhead: Double = 0
    var gpuBytes: UInt64 = 0
    var errorMessage: String? = nil
}

nonisolated final class GraciaRenderLink: @unchecked Sendable {
    private let lock = NSLock()

    // MARK: 입력(UI → 렌더 스레드)

    private var _source: GraciaSceneSource?
    /// 새 장면을 고를 때마다 증가. 같은 URL 이어도 다시 로드하게 한다.
    private var _sceneGeneration = 0
    private var _isPlaying = true
    private var _playbackSpeed: Double = 1
    private var _seek: Double?
    private var _immersion: GraciaImmersionMode = .mixed
    private var _recenter = false

    // MARK: 출력(렌더 스레드 → UI)

    private var _status = GraciaStatus()

    /// 프레임마다 한 번 찍는 일관된 입력 스냅샷. `seek` 는 여기서 소비된다.
    struct Inputs: Sendable {
        var source: GraciaSceneSource?
        var sceneGeneration: Int
        var isPlaying: Bool
        var playbackSpeed: Double
        var seek: Double?
        var immersion: GraciaImmersionMode
        var recenter: Bool
    }

    // MARK: UI 쪽

    func setScene(_ source: GraciaSceneSource?) {
        lock.withLock {
            _source = source
            _sceneGeneration += 1
            _seek = 0
            _isPlaying = true
        }
    }

    func setPlaying(_ v: Bool) { lock.withLock { _isPlaying = v } }
    func setPlaybackSpeed(_ v: Double) { lock.withLock { _playbackSpeed = v } }
    func seek(to t: Double) { lock.withLock { _seek = t } }
    func setImmersion(_ m: GraciaImmersionMode) { lock.withLock { _immersion = m } }
    func requestRecenter() { lock.withLock { _recenter = true } }

    /// 렌더러가 실제로 배치를 적용한 뒤에만 지운다(배치 전에 중단된 프레임이 탭을 삼키지 않도록).
    func consumeRecenter() { lock.withLock { _recenter = false } }

    func status() -> GraciaStatus { lock.withLock { _status } }

    // MARK: 렌더 쪽

    func takeInputs() -> Inputs {
        lock.withLock {
            let seek = _seek
            _seek = nil
            return Inputs(
                source: _source,
                sceneGeneration: _sceneGeneration,
                isPlaying: _isPlaying,
                playbackSpeed: _playbackSpeed,
                seek: seek,
                immersion: _immersion,
                recenter: _recenter
            )
        }
    }

    func publish(_ s: GraciaStatus) { lock.withLock { _status = s } }
}
