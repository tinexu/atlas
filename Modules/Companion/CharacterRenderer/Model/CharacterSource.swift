import Foundation

/// Where a character's model comes from. The three built-in characters are
/// built from primitives at runtime; a USDZ (e.g. exported from Blender)
/// can replace them once it passes `CharacterLimits`.
public enum CharacterSource: Equatable, Sendable {
    case procedural(CompanionSettings.Character)
    case usdz(URL)

    public static func from(_ settings: CompanionSettings) -> CharacterSource {
        if settings.character == .custom, let path = settings.customCharacterPath {
            return .usdz(URL(fileURLWithPath: path))
        }
        return .procedural(settings.character == .custom ? .robot : settings.character)
    }
}

/// Keeps imported characters cheap to draw in a corner of the screen.
public enum CharacterLimits {
    public static let maxFileBytes: Int64 = 25_000_000
    public static let maxTriangles = 60_000
    /// Longest side, in model units (metres in Reality Composer / Blender).
    public static let maxExtent: Float = 50
    public static let minExtent: Float = 0.001

    public struct Report: Equatable, Sendable {
        public let fileBytes: Int64
        public let triangles: Int
        public let extent: Float

        public init(fileBytes: Int64, triangles: Int, extent: Float) {
            self.fileBytes = fileBytes
            self.triangles = triangles
            self.extent = extent
        }
    }

    /// Nil when the model is fine to use; otherwise what's wrong, in words.
    public static func problem(with report: Report) -> String? {
        if report.fileBytes > maxFileBytes {
            return "The file is \(ByteCountFormatter.string(fromByteCount: report.fileBytes, countStyle: .file)). Characters can be up to \(ByteCountFormatter.string(fromByteCount: maxFileBytes, countStyle: .file))."
        }
        if report.triangles == 0 {
            return "The file has no visible geometry."
        }
        if report.triangles > maxTriangles {
            return "The model has \(report.triangles.formatted()) polygons. Keep it under \(maxTriangles.formatted()) (try Decimate in Blender)."
        }
        if !report.extent.isFinite || report.extent > maxExtent || report.extent < minExtent {
            return "The model's size looks wrong (\(report.extent) units across). Apply its scale in Blender and export again."
        }
        return nil
    }
}
