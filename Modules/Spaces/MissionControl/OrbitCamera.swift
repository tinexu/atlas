import RealityKit
import simd

/// A camera that circles a target point. Every change is clamped so the
/// world can't be lost off-screen, flipped upside down or zoomed through.
struct OrbitCamera: Equatable {
    var target: SIMD3<Float>
    /// Radians around the vertical axis; 0 looks toward -z.
    var yaw: Float
    /// Radians above the horizon.
    var pitch: Float
    var distance: Float

    /// Area the target may move within (x/z).
    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) = ([-5, -5], [5, 5])
    var distanceRange: ClosedRange<Float> = 2.5...30

    static let pitchRange: ClosedRange<Float> = 0.25...1.35
    static let yawRange: ClosedRange<Float> = -1.2...1.2

    static func == (lhs: OrbitCamera, rhs: OrbitCamera) -> Bool {
        lhs.target == rhs.target && lhs.yaw == rhs.yaw && lhs.pitch == rhs.pitch && lhs.distance == rhs.distance
    }

    /// Frames a world occupying `min`…`max` on x/z.
    static func overview(min: SIMD2<Float>, max: SIMD2<Float>) -> OrbitCamera {
        let center = (min + max) / 2
        let extent = simd_max(max - min, [4, 4])
        let fit = Swift.max(extent.x * 0.9, extent.y * 1.3) + 2.5
        var camera = OrbitCamera(target: [center.x, 0.3, center.y], yaw: 0, pitch: 0.62, distance: fit)
        camera.bounds = (min - 1, max + 1)
        camera.distanceRange = 2.5...Swift.max(fit * 1.6, 6)
        return camera
    }

    /// Drag in points: horizontal circles the target, vertical tilts.
    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch += dy * 0.006
        clamp()
    }

    /// `factor` > 1 moves closer.
    mutating func zoom(by factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        distance /= factor
        clamp()
    }

    mutating func focus(on point: SIMD3<Float>, distance: Float) {
        target = [point.x, 0.3, point.z]
        self.distance = distance
        clamp()
    }

    mutating func clamp() {
        yaw = yaw.clamped(to: Self.yawRange)
        pitch = pitch.clamped(to: Self.pitchRange)
        distance = distance.clamped(to: distanceRange)
        target.x = target.x.clamped(to: bounds.min.x...bounds.max.x)
        target.z = target.z.clamped(to: bounds.min.y...bounds.max.y)
    }

    var transform: Transform {
        let offset = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
        // Identity looks down -z; turn by yaw, then tilt down by pitch.
        let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
        return Transform(scale: .one, rotation: rotation, translation: target + offset)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
