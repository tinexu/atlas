import Foundation

// Mochi, the default Companion: an original kawaii bunny. This file is the
// headless half shared by the desktop overlay and the rooms: its colours,
// accessories and poses as plain data. `MochiRecipe` turns them into
// geometry; the renderers only draw it.

/// A colour preset. `custom` colours override single roles on top of one.
public enum MochiPreset: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case strawberryMilk, matcha, taro, mocha, midnight

    public var id: Self { self }

    public var title: String {
        switch self {
        case .strawberryMilk: return "Strawberry Milk"
        case .matcha: return "Matcha"
        case .taro: return "Taro"
        case .mocha: return "Mocha"
        case .midnight: return "Midnight"
        }
    }

    public var palette: MochiPalette {
        switch self {
        case .strawberryMilk:
            return MochiPalette(fur: "#FFF6F2", shade: "#F7E4E8", accent: "#F7A8BE", blush: "#FF9FB7", eye: "#3B2A3F", tummy: "#FFFFFF")
        case .matcha:
            return MochiPalette(fur: "#EEF5E6", shade: "#DDEBD3", accent: "#A8CFA0", blush: "#FF9FB7", eye: "#3B2A3F", tummy: "#FAFDF6")
        case .taro:
            return MochiPalette(fur: "#F1EAFB", shade: "#E3D7F6", accent: "#C3A8F0", blush: "#FF9FB7", eye: "#3B2A3F", tummy: "#FBF8FF")
        case .mocha:
            return MochiPalette(fur: "#EAD9C8", shade: "#DCC4AE", accent: "#C99A7A", blush: "#F59A9A", eye: "#3B2A3F", tummy: "#F7EEE5")
        case .midnight:
            return MochiPalette(fur: "#3B3550", shade: "#2E2940", accent: "#F7A8BE", blush: "#FF9FB7", eye: "#17121F", tummy: "#4A4363",
                                highlight: 2.2)
        }
    }
}

/// Every colour Mochi is drawn with, as "#RRGGBB".
public struct MochiPalette: Codable, Hashable, Sendable {
    /// Warm white body and head.
    public var fur: String
    /// The back of the head and body, for a subtle two-tone.
    public var shade: String
    /// Inner ears, nose and paw pads.
    public var accent: String
    /// Cheek blush, drawn at about 45% opacity.
    public var blush: String
    public var eye: String
    public var tummy: String
    /// Brightness of the eye sparkles (Midnight's are brighter).
    public var highlight: Float

    public init(fur: String, shade: String, accent: String, blush: String, eye: String, tummy: String, highlight: Float = 1.2) {
        self.fur = fur
        self.shade = shade
        self.accent = accent
        self.blush = blush
        self.eye = eye
        self.tummy = tummy
        self.highlight = highlight
    }

    public static let blushOpacity: Float = 0.45
}

/// Which ear flops over the side of the head (as you look at Mochi).
public enum MochiFloppyEar: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case left, right, none
    public var id: Self { self }
    public var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .none: return "None (both up)"
        }
    }
}

/// How Mochi looks: a preset, any custom colours, and its floppy ear.
public struct MochiLook: Codable, Hashable, Sendable {
    public var preset: MochiPreset = .strawberryMilk
    /// Custom colours; nil uses the preset's.
    public var fur: String?
    public var accent: String?
    public var eye: String?
    public var floppyEar: MochiFloppyEar = .right

    public init(preset: MochiPreset = .strawberryMilk, fur: String? = nil, accent: String? = nil, eye: String? = nil,
                floppyEar: MochiFloppyEar = .right) {
        self.preset = preset
        self.fur = fur
        self.accent = accent
        self.eye = eye
        self.floppyEar = floppyEar
    }

    public var isCustom: Bool { fur != nil || accent != nil || eye != nil }

    /// The preset with the custom colours applied. A custom fur colour
    /// derives its shading and tummy from it, so the two-tone still reads.
    public var palette: MochiPalette {
        var palette = preset.palette
        if let fur {
            palette.fur = fur
            palette.shade = MochiColor.mix(fur, "#B07A8A", 0.1)
            palette.tummy = MochiColor.mix(fur, "#FFFFFF", 0.6)
        }
        if let accent { palette.accent = accent }
        if let eye { palette.eye = eye }
        return palette
    }

    /// Applies a preset and clears custom colours.
    public mutating func choose(_ preset: MochiPreset) {
        self.preset = preset
        fur = nil
        accent = nil
        eye = nil
    }

    /// A stable string for caches.
    public var key: String {
        let p = palette
        return "\(p.fur)\(p.shade)\(p.accent)\(p.blush)\(p.eye)\(p.tummy)\(p.highlight)|\(floppyEar.rawValue)"
    }
}

/// Small things Mochi can wear or hold. One or two at a time.
public enum MochiAccessory: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    /// Lavender over-ear headphones (Coding Lab).
    case headphones
    /// Round brass glasses (Study Library).
    case glasses
    /// A tiny sage scarf (Study Library).
    case scarf
    /// A small rose beret (Creative Studio).
    case beret
    /// A paint smudge on one cheek (Creative Studio).
    case paintSmudge
    /// A striped popcorn box in its paws (Watch mode).
    case popcorn
    /// A tiny sprout on the floppy ear.
    case sprout
    /// A bow on the floppy ear.
    case bow

    public var id: Self { self }

    public var title: String {
        switch self {
        case .headphones: return "Headphones"
        case .glasses: return "Glasses"
        case .scarf: return "Scarf"
        case .beret: return "Beret"
        case .paintSmudge: return "Paint smudge"
        case .popcorn: return "Popcorn"
        case .sprout: return "Sprout"
        case .bow: return "Bow"
        }
    }

    public static let maxWorn = 2
}

/// Where Mochi is, for choosing what it wears.
public enum MochiRoom: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case codingLab, studyLibrary, creativeStudio, watch, desktop

    public var id: Self { self }

    public var title: String {
        switch self {
        case .codingLab: return "Coding Lab"
        case .studyLibrary: return "Study Library"
        case .creativeStudio: return "Creative Studio"
        case .watch: return "Watch mode"
        case .desktop: return "Outside rooms"
        }
    }

    public var defaultAccessories: [MochiAccessory] {
        switch self {
        case .codingLab: return [.headphones]
        case .studyLibrary: return [.glasses, .scarf]
        case .creativeStudio: return [.beret, .paintSmudge]
        case .watch: return [.popcorn]
        case .desktop: return [.sprout]
        }
    }

    /// Watch mode wins over the Space it's in; Spaces made from one of the
    /// room templates count as that room; anything else is the desktop.
    public static func resolve(templateID: String?, isWatching: Bool) -> MochiRoom {
        if isWatching { return .watch }
        switch templateID {
        case CodingLab.templateID: return .codingLab
        case StudyLibrary.templateID: return .studyLibrary
        case CreativeLoft.templateID: return .creativeStudio
        default: return .desktop
        }
    }
}

/// What Mochi wears where. With `auto` on (the default) it changes with
/// the room; off, it wears the "outside rooms" choice everywhere.
public struct MochiAccessorySettings: Codable, Hashable, Sendable {
    public var auto = true
    /// Per room; a missing room uses its default.
    public var perRoom: [MochiRoom: [MochiAccessory]] = [:]

    public init(auto: Bool = true, perRoom: [MochiRoom: [MochiAccessory]] = [:]) {
        self.auto = auto
        self.perRoom = perRoom
    }

    public func chosen(for room: MochiRoom) -> [MochiAccessory] {
        Array((perRoom[room] ?? room.defaultAccessories).prefix(MochiAccessory.maxWorn))
    }

    /// What to wear in `room` right now.
    public func accessories(for room: MochiRoom) -> [MochiAccessory] {
        chosen(for: auto ? room : .desktop)
    }

    /// Turns one accessory on or off for a room, keeping at most two (the
    /// oldest goes when a third is added).
    public mutating func toggle(_ accessory: MochiAccessory, in room: MochiRoom) {
        var list = chosen(for: room)
        if let index = list.firstIndex(of: accessory) {
            list.remove(at: index)
        } else {
            list.append(accessory)
            if list.count > MochiAccessory.maxWorn { list.removeFirst(list.count - MochiAccessory.maxWorn) }
        }
        perRoom[room] = list
    }
}

/// Everything about Mochi's appearance, stored with the Companion settings.
public struct MochiSettings: Codable, Hashable, Sendable {
    public var look = MochiLook()
    public var accessories = MochiAccessorySettings()

    public init(look: MochiLook = MochiLook(), accessories: MochiAccessorySettings = MochiAccessorySettings()) {
        self.look = look
        self.accessories = accessories
    }
}

// MARK: - Pose

/// A held body pose plus expression. The renderer moves joints to match;
/// animation (breathing, hops) plays on top.
public struct MochiPosture: Hashable, Sendable {
    public enum Body: String, Hashable, Sendable {
        /// Standing (overlay, painting).
        case stand
        /// Sitting upright (desk corner, window seat).
        case sit
        /// The "loaf": paws tucked, body lowered.
        case loaf
    }

    public enum Eyes: String, Hashable, Sendable {
        case open, wide, half, happy, closed, down
    }

    public enum Mouth: String, Hashable, Sendable {
        /// The tiny "w" smile.
        case smile
        /// A small "o" (surprise, chewing).
        case open
        /// A wobbly little frown.
        case frown
    }

    public enum Paws: String, Hashable, Sendable {
        /// Resting on the tummy.
        case rest
        /// One paw up to its chin (thinking).
        case chin
        /// Both paws holding something in front (a book, popcorn).
        case hold
        /// One paw out holding a brush.
        case brush
        /// Tucked away (the loaf).
        case tucked
        /// One paw to its mouth (eating popcorn).
        case toMouth
    }

    public var body: Body = .stand
    /// Roll of the head in radians; positive leans towards your right.
    public var headTilt: Float = 0
    /// Yaw of the head in radians (looking at the cursor).
    public var headTurn: Float = 0
    /// Pitch of the head; positive looks down.
    public var headNod: Float = 0
    /// 0 relaxed, 1 perked up.
    public var perk: Float = 0
    /// How far the floppy ear lifts: 0 flopped, 1 fully up.
    public var floppyLift: Float = 0
    /// Ears drooped flat (failure).
    public var droop = false
    /// Ears laid back softly (the loaf).
    public var earsBack = false
    public var eyes: Eyes = .open
    /// Eye size multiplier (listening makes them a little bigger).
    public var eyeScale: Float = 1
    public var mouth: Mouth = .smile
    public var paws: Paws = .rest
    public var cheeksPuffed = false
    public var sweat = false

    public init() {}

    public static let idle = MochiPosture()
}

/// Mochi in a room: what it's doing there and what it wears.
public enum MochiRoomPose {
    public enum Activity: String, Sendable {
        /// Study Library: the loaf on the window seat with a tiny book.
        case reading
        /// Creative Studio: standing at a tiny easel with a brush.
        case painting
        /// Watch mode: on the window seat with popcorn.
        case watching
        /// Coding Lab: sitting on the desk corner, bobbing to music.
        case coding
        /// Coding Lab during lockdown: the loaf.
        case lockdown
    }

    public static func posture(_ activity: Activity, focused: Bool = false) -> MochiPosture {
        var p = MochiPosture()
        switch activity {
        case .reading:
            p.body = .loaf
            p.paws = .hold
            p.eyes = focused ? .half : .down
            p.headNod = 0.14
        case .painting:
            p.paws = .brush
            p.headTilt = 0.08
            if focused { p.eyes = .half }
        case .watching:
            p.body = .sit
            p.paws = .hold
        case .coding:
            p.body = .sit
            p.eyes = focused ? .half : .open
        case .lockdown:
            p.body = .loaf
            p.paws = .tucked
            p.earsBack = true
            p.eyes = .half
        }
        return p
    }
}
