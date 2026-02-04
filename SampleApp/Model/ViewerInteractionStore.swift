import CoreGraphics
import os
import simd

struct ViewerInteractionSnapshot: Sendable, Equatable {
    var orientation: simd_quatf
    var scale: Float

    static let identity = ViewerInteractionSnapshot(orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                                                    scale: 1)
}

final class ViewerInteractionStore: @unchecked Sendable {
    private var state = OSAllocatedUnfairLock(uncheckedState: ViewerInteractionSnapshot.identity)

    func snapshot() -> ViewerInteractionSnapshot {
        state.withLock { $0 }
    }

    func reset() {
        state.withLock { $0 = .identity }
    }

    func applyScale(factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        state.withLock {
            let next = ($0.scale * factor).clamped(to: 0.05 ... 20)
            $0.scale = next
        }
    }

    func applyArcballDrag(from start: CGPoint, to end: CGPoint, in size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        guard size.width > 0, size.height > 0 else { return }

        let v0 = projectToArcball(start, in: size)
        let v1 = projectToArcball(end, in: size)

        let delta = quaternion(from: v0, to: v1)
        guard delta.angle.isFinite else { return }
        if delta.angle == 0 { return }

        state.withLock {
            $0.orientation = simd_normalize(delta * $0.orientation)
        }
    }

    private func projectToArcball(_ point: CGPoint, in size: CGSize) -> SIMD3<Float> {
        let w = Float(size.width)
        let h = Float(size.height)
        let x = (2 * Float(point.x) - w) / w
        let y = (h - 2 * Float(point.y)) / h

        let lengthSquared = x * x + y * y
        if lengthSquared <= 1 {
            let z = sqrt(1 - lengthSquared)
            return simd_normalize(SIMD3(x, y, z))
        }

        let invLength = 1 / sqrt(lengthSquared)
        return SIMD3(x * invLength, y * invLength, 0)
    }

    private func quaternion(from v0: SIMD3<Float>, to v1: SIMD3<Float>) -> simd_quatf {
        let dot = simd_clamp(simd_dot(v0, v1), -1, 1)

        if dot > 0.999_999 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        if dot < -0.999_999 {
            let axis: SIMD3<Float>
            if abs(v0.x) < 0.1 {
                axis = simd_normalize(simd_cross(v0, SIMD3<Float>(1, 0, 0)))
            } else {
                axis = simd_normalize(simd_cross(v0, SIMD3<Float>(0, 1, 0)))
            }
            return simd_quatf(angle: .pi, axis: axis)
        }

        let axis = simd_cross(v0, v1)
        return simd_normalize(simd_quatf(vector: SIMD4<Float>(axis.x, axis.y, axis.z, 1 + dot)))
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        max(range.lowerBound, min(range.upperBound, self))
    }
}

