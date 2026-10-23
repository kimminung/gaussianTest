#if os(visionOS)
//
//  양손 핀치로 장면을 옮기고(한 손) 키우고 돌리는(두 손) 컨트롤러.
//  gracia-labs/apple-sdk 의 visionOS 데모(MIT, © 2026 Gracia Labs and contributors)
//  `SpatialGestureController.swift` 포팅.
//
//  스레딩: `handleSpatialEvents` 는 메인 액터(`layerRenderer.onSpatialEvent`)에서 핀치 위치 스냅샷만 쓰고,
//  `update()` 는 렌더 스레드에서 프레임마다 적용한다. 모델 행렬은 렌더 스레드 전용.
//

import SwiftUI
import os
import simd

nonisolated final class GraciaSpatialGestureController: @unchecked Sendable {

    private struct PinchSnapshot {
        var left: SIMD3<Float>?
        var right: SIMD3<Float>?
    }
    private let pinchLock = OSAllocatedUnfairLock(initialState: PinchSnapshot())

    private var currentModelMatrix = matrix_identity_float4x4

    private enum GestureState {
        case idle
        case oneHandDrag(pinch: SIMD3<Float>)
        case twoHand(midpoint: SIMD3<Float>, distance: Float, angle: Float, startMatrix: simd_float4x4)
    }
    private var state: GestureState = .idle
    private var smoothedPinch: SIMD3<Float>?
    private let smoothing: Float = 0.45

    var lockPosition = false
    var lockScale = false

    // MARK: 메인 액터: 공간 이벤트

    func handleSpatialEvents(_ events: SpatialEventCollection) {
        var left: SIMD3<Float>?
        var right: SIMD3<Float>?
        for event in events {
            guard event.kind == .indirectPinch || event.kind == .directPinch else { continue }
            guard event.phase == .active else { continue }
            let pos = Self.position(of: event)
            if event.chirality == .left { left = pos } else if event.chirality == .right { right = pos }
        }
        let (l, r) = (left, right)
        pinchLock.withLock { $0.left = l; $0.right = r }
    }

    private static func position(of event: SpatialEventCollection.Event) -> SIMD3<Float> {
        if let pose = event.inputDevicePose {
            let p = pose.pose3D.position
            return SIMD3(Float(p.x), Float(p.y), Float(p.z))
        }
        let p = event.location3D
        return SIMD3(Float(p.x), Float(p.y), Float(p.z))
    }

    // MARK: 렌더 스레드: 프레임마다 적용

    func update() {
        let snap = pinchLock.withLock { $0 }
        switch (snap.left, snap.right) {
        case let (.some(l), .some(r)): applyTwoHand(left: l, right: r)
        case let (.some(p), .none): applyOneHand(p)
        case let (.none, .some(p)): applyOneHand(p)
        case (.none, .none):
            state = .idle
            smoothedPinch = nil
        }
    }

    private func applyOneHand(_ pos: SIMD3<Float>) {
        if lockPosition {
            state = .oneHandDrag(pinch: pos)
            smoothedPinch = nil
            return
        }
        let smoothed = smoothedPinch.map { simd_mix($0, pos, SIMD3(repeating: smoothing)) } ?? pos
        smoothedPinch = smoothed
        if case .oneHandDrag(let prev) = state {
            currentModelMatrix = Self.translation(smoothed - prev) * currentModelMatrix
        }
        state = .oneHandDrag(pinch: smoothed)
    }

    private func applyTwoHand(left: SIMD3<Float>, right: SIMD3<Float>) {
        let mid = (left + right) * 0.5
        let dist = simd_distance(left, right)
        let angle = atan2(right.x - left.x, right.z - left.z)
        guard case .twoHand(let mid0, let dist0, let angle0, let start) = state else {
            state = .twoHand(midpoint: mid, distance: dist, angle: angle, startMatrix: currentModelMatrix)
            return
        }
        let scaleRatio = lockScale ? 1 : dist / max(dist0, 0.001)
        let recenter = lockPosition ? Self.translation(mid0) : Self.translation(mid)
        currentModelMatrix = recenter * Self.rotationY(angle - angle0) * Self.scale(scaleRatio) * Self.translation(-mid0) * start
    }

    // MARK: 배치 / 읽기

    func resetToMatrix(_ m: simd_float4x4) {
        currentModelMatrix = m
        state = .idle
        smoothedPinch = nil
        pinchLock.withLock { $0.left = nil; $0.right = nil }
    }

    var modelMatrix: simd_float4x4 { currentModelMatrix }

    // MARK: 행렬 도우미

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func scale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    static func rotationY(_ radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: SIMD3(0, 1, 0)))
    }
}
#endif
