import AtlasSpaces
import Foundation

/// How Mochi shows a Companion state: a held posture and expression, plus
/// what moves on top of it. Pure, so tests can check every state at every
/// intensity.
public struct MochiPose: Equatable, Sendable {
    public enum Motion: String, Equatable, Sendable {
        case none
        /// Breathing, blinking, an ear twitch and nose wiggle now and then.
        case idle
        /// Gentle hops in place (working), ears bouncing behind.
        case hops
        /// One high hop with a mid-air twist (success).
        case binky
        /// A slow sigh, body squashing a little (failure).
        case sigh
        /// One happy hop (clicked or petted).
        case happyHop
    }

    public enum Effect: String, Equatable, Sendable {
        case none
        /// Three tiny dots above the head, pulsing one by one.
        case thinkingDots
        /// A burst of pink and white stars that fade.
        case sparkles
        /// "z z z" drifting up.
        case zzz
    }

    public var posture: MochiPosture
    public var motion: Motion
    /// Seconds per breath; 0 doesn't breathe.
    public var breathPeriod: Double
    public var blinks: Bool
    public var earTwitch: Bool
    public var noseWiggle: Bool
    public var effect: Effect
    /// Effects move (dots pulse, z's drift); false shows them still.
    public var effectsMove: Bool
    /// Where the cursor is, -1…1 on each axis from the character's centre
    /// (y up), while hovering; the head follows within ±15°.
    public var lookAt: SIMD2<Float>?

    public static let hopHeight: Float = 0.25
    public static let hopInterval: TimeInterval = 0.6
    public static let binkyHeight: Float = 0.5
    /// 8% squash on landing.
    public static let squash: Float = 0.08
    public static let breath: Float = 0.02
    public static let lookLimit: Float = 15 * .pi / 180
    public static let listeningTilt: Float = 10 * .pi / 180

    public init(posture: MochiPosture = .idle, motion: Motion = .idle, breathPeriod: Double = 3, blinks: Bool = true, earTwitch: Bool = true,
                noseWiggle: Bool = true, effect: Effect = .none, effectsMove: Bool = true, lookAt: SIMD2<Float>? = nil) {
        self.posture = posture
        self.motion = motion
        self.breathPeriod = breathPeriod
        self.blinks = blinks
        self.earTwitch = earTwitch
        self.noseWiggle = noseWiggle
        self.effect = effect
        self.effectsMove = effectsMove
        self.lookAt = lookAt
    }

    /// `reading`: a study session's focus (the loaf, holding a book).
    /// `hover`: the cursor over the interactive overlay. `petted`: a click
    /// or "Pet Mochi" (a happy hop).
    public static func make(for state: CompanionState, intensity: CompanionSettings.Intensity, reduceMotion: Bool,
                            reading: Bool = false, hover: SIMD2<Float>? = nil, petted: Bool = false) -> MochiPose {
        // Still: a static idle pose, whatever is happening.
        if intensity == .still {
            return MochiPose(motion: .none, breathPeriod: 0, blinks: false, earTwitch: false, noseWiggle: false, effectsMove: false)
        }

        var pose = MochiPose()
        var p = MochiPosture()
        switch state {
        case .idle:
            break
        case .listening:
            // Both ears perk up (the floppy one lifts halfway), head tilts, eyes a little bigger.
            p.perk = 1
            p.floppyLift = 0.5
            p.headTilt = listeningTilt
            p.eyes = .wide
            pose.earTwitch = false
        case .thinking:
            p.headTilt = -listeningTilt
            p.paws = .chin
            pose.effect = .thinkingDots
            pose.earTwitch = false
            pose.noseWiggle = false
        case .executing:
            pose.motion = .hops
            pose.breathPeriod = 0
            pose.earTwitch = false
            pose.noseWiggle = false
        case .success:
            p.eyes = .happy
            pose.motion = .binky
            pose.effect = .sparkles
            pose.breathPeriod = 0
            pose.blinks = false
            pose.earTwitch = false
        case .failure:
            p.droop = true
            p.eyes = .down
            p.mouth = .frown
            p.sweat = true
            pose.motion = .sigh
            pose.breathPeriod = 0
            pose.earTwitch = false
            pose.noseWiggle = false
        case .focus:
            // The loaf: breathing only.
            p.body = .loaf
            p.paws = .tucked
            p.earsBack = true
            p.eyes = .half
            pose = MochiPose(motion: .idle, breathPeriod: 3.5, blinks: false, earTwitch: false, noseWiggle: false)
        case .sleeping:
            p.body = .loaf
            p.paws = .tucked
            p.earsBack = true
            p.eyes = .closed
            pose = MochiPose(motion: .idle, breathPeriod: 5, blinks: false, earTwitch: false, noseWiggle: false, effect: .zzz)
        }
        if reading && (state == .focus || state == .idle) {
            p = MochiPosture()
            p.body = .loaf
            p.paws = .hold
            p.eyes = .down
            p.headNod = 0.12
            pose = MochiPose(motion: .idle, breathPeriod: 3.5, blinks: true, earTwitch: false, noseWiggle: false)
        }
        if let hover, state == .idle || state == .listening {
            pose.lookAt = SIMD2(min(max(hover.x, -1), 1), min(max(hover.y, -1), 1))
            p.headTurn = pose.lookAt!.x * lookLimit
            p.headNod -= pose.lookAt!.y * lookLimit
            pose.noseWiggle = true
        }
        if petted, state != .executing, state != .success, state != .failure {
            p.eyes = .happy
            pose.motion = .happyHop
            pose.blinks = false
        }
        pose.posture = p

        if intensity == .reduced || reduceMotion {
            // Expressions (eyes, mouth, ears) and colour only: nothing hops,
            // bounces or sparkles, and the head doesn't chase the cursor.
            pose.motion = .none
            pose.breathPeriod = 0
            pose.earTwitch = false
            pose.noseWiggle = false
            pose.effectsMove = false
            if pose.effect == .sparkles { pose.effect = .none }
            if pose.lookAt != nil {
                pose.lookAt = nil
                pose.posture.headTurn = 0
                pose.posture.headNod = reading ? 0.12 : 0
            }
        }
        return pose
    }

    public var isStill: Bool {
        motion == .none && breathPeriod == 0 && !blinks && !earTwitch && !noseWiggle && (effect == .none || !effectsMove)
    }
}
