#if os(visionOS)
//
//  Gracia 장면을 Vision Pro 디스플레이에 스테레오로 그리는 Compositor Services 렌더 루프.
//  gracia-labs/apple-sdk 의 visionOS 데모(MIT, © 2026 Gracia Labs and contributors)
//  `ImmersiveRenderer.swift` / `LayerConfiguration.swift` / `Placement.swift` 를 무대(Mudae) 에 맞게 포팅.
//
//  - 두 눈의 RenderView 는 드로어블에서 직접 나온다(눈별 projection + 디바이스 앵커 × 눈 변환).
//  - `.rightUpBack` 은 Gracia 카메라 기저와 동일하므로 뒤집기·전치가 없다. 리버스 Z.
//  - 멀티뷰: 한 번의 정점 증폭 드로우로 2 슬라이스 레이어드 텍스처에 양 눈을 그린다.
//  - 수명 규칙: `Frame` 은 커맨드 버퍼 완료까지 보관, 장면/렌더러 교체 전 `waitUntilIdle()`.
//

import ARKit
import CompositorServices
import GraciaSDK
import Metal
import QuartzCore
import SwiftUI
import simd

// MARK: - 레이어 설정

nonisolated struct GraciaLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration
    ) {
        // Gracia 에는 BGRA 포맷이 없으므로 표현 가능한 포맷 중에서 고른다.
        let colors = capabilities.supportedColorFormats(options: [])
        let graciaColors: [MTLPixelFormat] = [.rgba16Float, .rgba8Unorm_srgb, .rgba8Unorm]
        configuration.colorFormat = graciaColors.first(where: colors.contains) ?? .rgba16Float

        let depths = capabilities.supportedDepthFormats
        configuration.depthFormat = depths.contains(.depth32Float) ? .depth32Float : (depths.first ?? .depth32Float)

        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        let layoutOptions: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            foveationEnabled ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: layoutOptions)
        configuration.layout =
            layouts.contains(.layered) ? .layered : (layouts.contains(.shared) ? .shared : .dedicated)
    }
}

// MARK: - 초기 배치

nonisolated enum GraciaPlacement {
    /// 장면 경계 중심을 머리 앞 `distance` m 에, 반지름이 `targetRadius` m 가 되게 정규화해 놓는다.
    static func initial(
        box: BoundingBox, head: simd_float4x4?, distance: Float = 1.2, targetRadius: Float = 0.5,
        drop: Float = 0.15
    ) -> simd_float4x4 {
        let center = box.isValid ? box.center : .zero
        let radius = box.isValid ? max(box.radius, 1e-3) : 1
        let s = targetRadius / radius

        let headPos = head.map(headPosition) ?? .zero
        let yaw = head.map(headYaw) ?? 0
        let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
        let target = headPos + forward * distance + SIMD3(0, -drop, 0)

        let place = simd_float4x4(
            translation: target, rotation: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)),
            scale: SIMD3(repeating: s))
        let centerToOrigin = simd_float4x4(
            translation: -center, rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
            scale: SIMD3(repeating: 1))
        return place * centerToOrigin
    }

    static func headPosition(_ deviceToWorld: simd_float4x4) -> SIMD3<Float> {
        let c = deviceToWorld.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    static func headYaw(_ deviceToWorld: simd_float4x4) -> Float {
        let forward = -SIMD3<Float>(
            deviceToWorld.columns.2.x, deviceToWorld.columns.2.y, deviceToWorld.columns.2.z)
        return atan2(-forward.x, -forward.z)
    }
}

// MARK: - 렌더러

nonisolated final class GraciaImmersiveRenderer: @unchecked Sendable {
    private let layerRenderer: LayerRenderer
    private let link: GraciaRenderLink

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    /// GPU 디버거가 붙어 있으면 nil. 그 경우 화면만 클리어하고 오류를 보고한다.
    private let context: GraciaContext?
    private let pass: SplatsPassDescriptor

    /// Gracia 내부 3프레임 링에 맞춘 동시 진행 제한.
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private let onExit: (@Sendable () -> Void)?

    // 렌더 스레드 소유
    private var scenes: [GraciaSDK.Scene] = []
    private var renderer: SplatsRenderer?
    private var loadedGeneration = -1
    private var statusError: String?

    private var playhead: Double = 0
    private var isReady = true
    private var appliedSettle = true

    let gestureController = GraciaSpatialGestureController()
    private var needsPlacement = false

    private var lastTime: CFTimeInterval = 0
    private var smoothedDt: CFTimeInterval = 1.0 / 90
    private var smoothedFPS: Double = 0

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    init(layerRenderer: LayerRenderer, link: GraciaRenderLink, onExit: (@Sendable () -> Void)? = nil) {
        self.layerRenderer = layerRenderer
        self.link = link
        self.onExit = onExit

        let device = layerRenderer.device
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.context = try? GraciaContext(device: device, commandQueue: queue)
        self.pass = GraciaImmersiveRenderer.makePass(for: layerRenderer)
    }

    /// 레이어의 실제 색/깊이 포맷에 맞춘 Gracia 패스. `GraciaLayerConfiguration` 과 짝이다.
    private static func makePass(for layerRenderer: LayerRenderer) -> SplatsPassDescriptor {
        let cfg = layerRenderer.configuration
        let color: ColorFormat = {
            switch cfg.colorFormat {
            case .rgba16Float: .rgba16Float
            case .rgba8Unorm: .rgba8Unorm
            case .rgba8Unorm_srgb: .rgba8Srgb
            case .rgba32Float: .rgba32Float
            default: .rgba16Float
            }
        }()
        let depth: DepthFormat = {
            switch cfg.depthFormat {
            case .depth32Float: .d32Float
            case .depth16Unorm: .d16Unorm
            case .depth32Float_stencil8: .d32FloatS8Uint
            default: .d32Float
            }
        }()
        return SplatsPassDescriptor(
            colorFormat: color,
            depth: .splats(format: depth, reverseZ: true),
            sampleCount: 1,
            stereo: .multiview,
            depthStereo: .multiview)
    }

    // MARK: 스레드

    /// 렌더 루프를 전용 스레드로 넘기고 즉시 돌아온다(메인 액터 렌더 클로저에서 호출되므로 블록 금지).
    func start() {
        let thread = Thread { [self] in self.run() }
        thread.name = "com.coulson.mudae.gracia-render"
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func run() {
        startTracking()
        loop: while true {
            switch layerRenderer.state {
            case .paused:
                layerRenderer.waitUntilRunning()
            case .running:
                autoreleasepool { renderFrame() }
            case .invalidated:
                break loop
            @unknown default:
                break loop
            }
        }
        teardown()
        onExit?()
    }

    private func startTracking() {
        guard WorldTrackingProvider.isSupported else { return }
        let session = arSession
        let provider = worldTracking
        Task { try? await session.run([provider]) }
    }

    private func teardown() {
        context?.waitUntilIdle()
        scenes = []
        renderer = nil
        let session = arSession
        Task { session.stop() }
    }

    // MARK: 프레임

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        let inputs = link.takeInputs()
        loadSceneIfNeeded(inputs)
        let dt = tickClock()
        advancePlayback(inputs: inputs, dt: dt)
        settleIfNeeded()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()

        // 드로어블이 없으면(기기 벗음·공간 종료 중) endSubmission 없이 돌아간다.
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }
        defer { frame.endSubmission() }

        let deviceAnchor = worldTracking.queryDeviceAnchor(
            atTimestamp: drawables[0].frameTiming.presentationTime.timeInterval)
        placeScene(inputs: inputs, anchor: deviceAnchor)

        let canRender = inFlightSemaphore.wait(timeout: .now() + .milliseconds(200)) == .success

        guard let commandBuffer = queue.makeCommandBuffer() else {
            if canRender { inFlightSemaphore.signal() }
            return
        }

        if canRender {
            var heldFrames: [GraciaSDK.Frame] = []
            for drawable in drawables {
                if let held = encode(drawable, inputs: inputs, anchor: deviceAnchor, commandBuffer: commandBuffer) {
                    heldFrames.append(held)
                }
            }
            for drawable in drawables { drawable.encodePresent(commandBuffer: commandBuffer) }
            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { _ in
                _ = heldFrames
                semaphore.signal()
            }
        } else {
            for drawable in drawables { drawable.encodePresent(commandBuffer: commandBuffer) }
        }
        commandBuffer.commit()

        publishStatus()
    }

    private func placeScene(inputs: GraciaRenderLink.Inputs, anchor deviceAnchor: DeviceAnchor?) {
        if inputs.recenter {
            needsPlacement = true
            link.consumeRecenter()
        }

        if needsPlacement, let scene = scenes.first {
            let box = scene.adaptiveBBox.isValid ? scene.adaptiveBBox : scene.boundingBox
            if box.isValid {
                let head = deviceAnchor?.isTracked == true ? deviceAnchor?.originFromAnchorTransform : nil
                gestureController.resetToMatrix(GraciaPlacement.initial(box: box, head: head))
                needsPlacement = false
            }
        }

        gestureController.update()
        guard !scenes.isEmpty else { return }
        let model = gestureController.modelMatrix
        for scene in scenes { scene.setTransform(model) }
    }

    private func encode(
        _ drawable: LayerRenderer.Drawable, inputs: GraciaRenderLink.Inputs,
        anchor: DeviceAnchor?, commandBuffer: any MTLCommandBuffer
    ) -> GraciaSDK.Frame? {
        drawable.deviceAnchor = anchor
        let worldFromDevice = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        let views: [RenderView] = drawable.views.indices.map { i in
            let projection = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
            let cameraToWorld = worldFromDevice * drawable.views[i].transform
            return RenderView(projection: projection, cameraToWorld: cameraToWorld)
        }

        let viewport = drawable.views[0].textureMap.viewport
        let width = UInt32(max(viewport.width, 1))
        let height = UInt32(max(viewport.height, 1))

        var held: GraciaSDK.Frame?
        if appliedSettle, let renderer, !scenes.isEmpty {
            held = renderer.render(
                scenes: scenes, views: views, targetWidth: width, targetHeight: height,
                pass: pass, commandBuffer: commandBuffer)
        }

        let clearAlpha = inputs.immersion.isPassthrough ? 0.0 : 1.0
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clearAlpha)
        descriptor.depthAttachment.texture = drawable.depthTextures[0]
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .store
        descriptor.depthAttachment.clearDepth = pass.clearDepth
        descriptor.renderTargetArrayLength = drawable.views.count
        if let rateMap = drawable.rasterizationRateMaps.first {
            descriptor.rasterizationRateMap = rateMap
        }

        let encoder: (any MTLRenderCommandEncoder)?
        if let renderer {
            encoder = renderer.makeRenderCommandEncoder(commandBuffer, descriptor: descriptor, pass: pass)
        } else {
            encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        }
        guard let encoder else { return held }

        // SDK 는 인코더 쪽 증폭을 설정하지 않으므로 여기서 두 뷰포트·매핑을 지정해야 오른쪽 눈이 그려진다.
        if let calls = held?.color.mono {
            encoder.setViewports([viewport, viewport])
            let mappings = [
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 1),
            ]
            encoder.setVertexAmplificationCount(2, viewMappings: mappings)
            calls.execute(into: encoder)
        }
        encoder.endEncoding()
        return held
    }

    // MARK: 장면 수명

    private func loadSceneIfNeeded(_ inputs: GraciaRenderLink.Inputs) {
        guard inputs.sceneGeneration != loadedGeneration else { return }
        loadedGeneration = inputs.sceneGeneration

        context?.waitUntilIdle()
        scenes = []
        renderer = nil
        playhead = 0
        isReady = true
        appliedSettle = true
        statusError = nil

        guard let context, let source = inputs.source else { return }
        do {
            let scene: GraciaSDK.Scene
            switch source {
            case .file(let url):
                scene = try GraciaSDK.Scene(url: url, context: context)
            case .stream(let url, let token):
                scene = try GraciaSDK.Scene(streamURL: url, context: context, token: token)
            }
            scenes = [scene]
            needsPlacement = true
            isReady = !scene.isVideo
            appliedSettle = scene.isSettled
            if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
            try rebuildRenderer()
        } catch {
            scenes = []
            renderer = nil
            statusError = "\(error)"
        }
    }

    private func rebuildRenderer() throws {
        guard let context, let scene = scenes.first else {
            renderer = nil
            return
        }
        renderer = nil
        let r = try SplatsRenderer(context: context, maxSplatsCount: max(scene.splatsBudget, 1), vr: true)
        r.setFlag("splats_count_readback", true)
        renderer = r
    }

    /// 스트림의 실제 메타데이터(예산·경계·길이)가 들어오면 렌더러를 실제 크기로 다시 만든다.
    private func settleIfNeeded() {
        guard let scene = scenes.first, !appliedSettle, scene.isSettled else { return }
        appliedSettle = true
        context?.waitUntilIdle()
        do {
            try rebuildRenderer()
        } catch {
            statusError = "\(error)"
            return
        }
        if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
    }

    private func advancePlayback(inputs: GraciaRenderLink.Inputs, dt: Double) {
        guard let scene = scenes.first, scene.isVideo else { return }
        if let seek = inputs.seek {
            let end = max(0, scene.duration - 0.001)
            playhead = min(max(0, seek), end)
            isReady = false
        }
        if inputs.isPlaying, isReady, scene.duration > 0 {
            playhead += dt * inputs.playbackSpeed
            if playhead >= scene.duration { playhead = 0 }
        }
        scene.setTime(playhead)
        isReady = scene.pump()
    }

    // MARK: 시계 / 상태

    private func tickClock() -> Double {
        let now = CACurrentMediaTime()
        if lastTime == 0 {
            smoothedDt = 1.0 / 90
        } else {
            let raw = min(now - lastTime, 0.25)
            smoothedDt += (raw - smoothedDt) * 0.2
        }
        lastTime = now
        if smoothedDt > 0 { smoothedFPS += (1 / smoothedDt - smoothedFPS) * 0.1 }
        return smoothedDt
    }

    private func publishStatus() {
        var status = GraciaStatus()
        if let scene = scenes.first {
            status.sceneName = scene.name
            status.loaded = true
            status.isVideo = scene.isVideo
            status.splatsBudget = scene.splatsBudget
            status.visibleSplats = renderer?.visibleSplatsCount ?? 0
            status.duration = scene.duration
            status.playhead = playhead
            status.buffering = scene.isVideo && !isReady
        }
        status.fps = smoothedFPS
        status.gpuBytes = context?.gpuAllocatedBytes ?? 0
        status.errorMessage = statusError
        link.publish(status)
    }
}

nonisolated extension LayerRenderer.Clock.Instant {
    /// `CACurrentMediaTime()` 도메인의 절대 초. `queryDeviceAnchor` 가 요구하는 타임스탬프.
    /// 렌더 스레드에서 읽으므로 기본 MainActor 격리에서 제외한다.
    var timeInterval: TimeInterval {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
#endif
