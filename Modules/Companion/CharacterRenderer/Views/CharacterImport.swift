import AtlasCompanion
import Foundation
import RealityKit

/// Loads a USDZ character to check it against `CharacterLimits` before use.
@MainActor
public enum CharacterImport {
    /// Nil when the file is fine; otherwise the problem in words.
    public static func problem(with url: URL) -> String? {
        guard url.pathExtension.lowercased() == "usdz" else { return "Choose a .usdz file (in Blender: File → Export → Universal Scene Description, then zip as USDZ)." }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard let entity = try? Entity.load(contentsOf: url) else { return "ATLAS couldn't open that file as a 3D model." }
        let bounds = entity.visualBounds(relativeTo: nil)
        let extent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        return CharacterLimits.problem(with: .init(fileBytes: bytes, triangles: triangles(in: entity), extent: extent))
    }

    static func triangles(in entity: Entity) -> Int {
        var count = 0
        if let model = entity.components[ModelComponent.self] {
            for meshModel in model.mesh.contents.models {
                for part in meshModel.parts {
                    count += (part.triangleIndices?.count ?? 0) / 3
                }
            }
        }
        for child in entity.children { count += triangles(in: child) }
        return count
    }
}
