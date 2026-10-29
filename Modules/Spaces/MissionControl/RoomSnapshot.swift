import AtlasSpaces
import Foundation

/// Everything Mission Control needs to draw one room. Plain data, so the
/// 3D layer never reaches into the app's state or runs anything itself.
public struct RoomSnapshot: Identifiable, Hashable {
    public var space: Space
    public var room: RoomLayout
    public var objects: [SpaceObject]
    public var status: SpaceStatus
    public var isActive: Bool
    /// The Study Library's courses and more, for that room only.
    public var study: StudyRoomState?

    public var id: UUID { space.id }

    public init(space: Space, room: RoomLayout, objects: [SpaceObject], status: SpaceStatus, isActive: Bool,
                study: StudyRoomState? = nil) {
        self.space = space
        self.room = room
        self.objects = objects
        self.status = status
        self.isActive = isActive
        self.study = study
    }

    /// What requires rebuilding the room's meshes when it changes. Status,
    /// selection, group and slot only update indicators or position.
    var geometry: Geometry {
        Geometry(name: space.name, accent: space.accentColor, room: room, objects: objects, study: study?.geometry ?? [])
    }

    struct Geometry: Hashable {
        var name: String
        var accent: String
        var room: RoomLayout
        var objects: [SpaceObject]
        var study: [String]
    }
}

/// Places rooms on the world grid: one row per group (in group order),
/// rooms ordered left to right within it.
enum WorldLayout {
    static let columnSpacing: Float = 3.2
    static let rowSpacing: Float = 3.8

    struct Row {
        var group: SpaceGroup
        var z: Float
        var labelX: Float
    }

    struct Result {
        var positions: [UUID: SIMD3<Float>]
        var rows: [Row]
        var min: SIMD2<Float>
        var max: SIMD2<Float>
    }

    static func layout(_ rooms: [RoomSnapshot]) -> Result {
        let ordered = rooms.map(\.space).worldOrdered
        var groups: [SpaceGroup] = []
        var byGroup: [SpaceGroup: [Space]] = [:]
        for space in ordered {
            if byGroup[space.group] == nil { groups.append(space.group) }
            byGroup[space.group, default: []].append(space)
        }
        let widest = groups.map { byGroup[$0]?.count ?? 0 }.max() ?? 0
        let originX = -Float(max(widest - 1, 0)) * columnSpacing / 2
        let originZ = -Float(max(groups.count - 1, 0)) * rowSpacing / 2

        var positions: [UUID: SIMD3<Float>] = [:]
        var rows: [Row] = []
        for (rowIndex, group) in groups.enumerated() {
            let z = originZ + Float(rowIndex) * rowSpacing
            for (column, space) in (byGroup[group] ?? []).enumerated() {
                positions[space.id] = [originX + Float(column) * columnSpacing, 0, z]
            }
            rows.append(Row(group: group, z: z, labelX: originX - columnSpacing * 0.62))
        }
        let halfRoom: Float = 1.2
        let xs = positions.values.map(\.x), zs = positions.values.map(\.z)
        let minPoint = SIMD2<Float>((xs.min() ?? 0) - halfRoom, (zs.min() ?? 0) - halfRoom)
        let maxPoint = SIMD2<Float>((xs.max() ?? 0) + halfRoom, (zs.max() ?? 0) + halfRoom)
        return Result(positions: positions, rows: rows, min: minPoint, max: maxPoint)
    }
}
