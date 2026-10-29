import Foundation
import UniformTypeIdentifiers

// Stage 05 Orbit: the data Orbit keeps about files. Only folders the user
// added are ever indexed, and all of it lives in the local database.

/// A folder the user explicitly added to Orbit. Everything Orbit reads, and
/// every file action ATLAS takes, stays inside these.
public struct FileLocation: Identifiable, Hashable, Sendable {
    public enum IndexState: String, Codable, Sendable {
        case pending, indexing, paused, complete, unavailable
    }

    public var id: UUID
    /// Absolute, standardized, no trailing slash.
    public var path: String
    public var name: String
    /// Security-scoped bookmark, so access survives relaunches (and sandboxing later).
    public var bookmark: Data?
    public var addedAt: Date
    public var lastIndexedAt: Date?
    public var fileCount: Int
    public var totalSize: Int64
    public var indexState: IndexState
    public var scanGeneration: Int

    public init(id: UUID = UUID(), path: String, name: String? = nil, bookmark: Data? = nil, addedAt: Date = Date(),
                lastIndexedAt: Date? = nil, fileCount: Int = 0, totalSize: Int64 = 0, indexState: IndexState = .pending,
                scanGeneration: Int = 0) {
        self.id = id
        self.path = FileLocation.normalize(path)
        self.name = name ?? FileLocation.displayName(for: FileLocation.normalize(path))
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.lastIndexedAt = lastIndexedAt
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.indexState = indexState
        self.scanGeneration = scanGeneration
    }

    /// Expands ~, removes `.`/`..` and any trailing slash.
    public static func normalize(_ path: String) -> String {
        let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// "Downloads", or "~" for the home folder.
    public static func displayName(for path: String) -> String {
        path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent
    }

    /// `path` is this folder or inside it.
    public func contains(_ path: String) -> Bool {
        FileLocation.isPath(path, inside: self.path)
    }

    public static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

/// The kind of thing a file is, for shapes, colours, filters and the legend.
public enum FileCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case folder, document, code, image, video, audio, archive, app, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: return "Folders"
        case .document: return "Documents"
        case .code: return "Code"
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archive: return "Archives & Installers"
        case .app: return "Apps"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .document: return "doc.text.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .archive: return "archivebox.fill"
        case .app: return "app.fill"
        case .other: return "doc.fill"
        }
    }

    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "java", "kt",
        "cs", "php", "sh", "zsh", "bash", "pl", "lua", "r", "scala", "sql", "html", "css", "scss", "json", "yaml", "yml",
        "toml", "xml", "ipynb", "md", "gradle", "make", "cmake", "dart", "vue", "svelte",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "mpkg", "iso", "xip",
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "txt", "rtf", "rtfd", "odt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key",
        "epub", "tex", "log",
    ]

    /// From the extension first (fast and predictable), then the UTType.
    public static func classify(extension ext: String, isDirectory: Bool, isPackage: Bool, typeIdentifier: String? = nil) -> FileCategory {
        let ext = ext.lowercased()
        if ext == "app" { return .app }
        if isDirectory && !isPackage { return .folder }
        if codeExtensions.contains(ext) { return .code }
        if archiveExtensions.contains(ext) { return .archive }
        if documentExtensions.contains(ext) { return .document }
        let type = typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: ext)
        guard let type else { return isPackage ? .other : .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .app }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}

/// One indexed file or folder.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var locationID: UUID
    public var parent: String
    public var name: String
    public var ext: String
    public var typeIdentifier: String?
    public var category: FileCategory
    /// Bytes; for a folder, everything inside it.
    public var size: Int64
    /// For a folder: files inside it, at any depth.
    public var itemCount: Int
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// When it was last opened, as far as macOS knows.
    public var accessedAt: Date?
    public var isDirectory: Bool
    /// Treated as a single file (.app, .photoslibrary…).
    public var isPackage: Bool
    public var inode: UInt64?

    public init(path: String, locationID: UUID, parent: String? = nil, name: String? = nil, ext: String? = nil,
                typeIdentifier: String? = nil, category: FileCategory? = nil, size: Int64 = 0, itemCount: Int = 0,
                createdAt: Date? = nil, modifiedAt: Date? = nil, accessedAt: Date? = nil, isDirectory: Bool = false,
                isPackage: Bool = false, inode: UInt64? = nil) {
        self.path = path
        self.locationID = locationID
        self.parent = parent ?? (path as NSString).deletingLastPathComponent
        self.name = name ?? (path as NSString).lastPathComponent
        let e = ext ?? (path as NSString).pathExtension.lowercased()
        self.ext = e
        self.typeIdentifier = typeIdentifier
        self.category = category ?? FileCategory.classify(extension: e, isDirectory: isDirectory, isPackage: isPackage,
                                                          typeIdentifier: typeIdentifier)
        self.size = size
        self.itemCount = itemCount
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.inode = inode
    }

    /// A folder you can go into (packages count as files).
    public var isFolder: Bool { isDirectory && !isPackage }
}

// MARK: - Projects

/// Files and folders from anywhere, grouped without moving them.
public struct Project: Identifiable, Hashable, Sendable {
    /// What activating the linked Space does with the project's key items.
    public enum SpaceBehavior: String, Codable, CaseIterable, Sendable {
        case none, reveal, open
        public var title: String {
            switch self {
            case .none: return "Nothing"
            case .reveal: return "Show key items in Finder"
            case .open: return "Open key items"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var color: String
    public var spaceID: UUID?
    public var spaceBehavior: SpaceBehavior
    public var createdAt: Date
    public var links: [ProjectLink]
    /// Set for a Creative Studio project; nil for a plain Orbit project.
    public var creative: CreativeInfo?

    public init(id: UUID = UUID(), name: String, color: String = "blue", spaceID: UUID? = nil,
                spaceBehavior: SpaceBehavior = .none, createdAt: Date = Date(), links: [ProjectLink] = [],
                creative: CreativeInfo? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.spaceID = spaceID
        self.spaceBehavior = spaceBehavior
        self.createdAt = createdAt
        self.links = links
        self.creative = creative
    }
}

/// What a Creative Studio project adds to an Orbit project: what kind of
/// work it is, the apps and main files it opens, its links, folders and
/// status. Kept together (v10 `project.creative_json`), so plain projects
/// are untouched.
public struct CreativeInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case design, threeD = "3d", illustration, video, photo, other

        public var title: String {
            switch self {
            case .design: return "Design"
            case .threeD: return "3D"
            case .illustration: return "Illustration"
            case .video: return "Video"
            case .photo: return "Photo"
            case .other: return "Other"
            }
        }
    }

    public enum Status: String, Codable, CaseIterable, Sendable {
        case idea, inProgress = "in_progress", done

        public var title: String {
            switch self {
            case .idea: return "Idea"
            case .inProgress: return "In progress"
            case .done: return "Done"
            }
        }
    }

    /// A web link: a Figma file, a Pinterest board, a brief, a tutorial…
    public struct Link: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case figma, pinterest, dribbble, brief, tutorial, other

            public var title: String {
                switch self {
                case .figma: return "Figma"
                case .pinterest: return "Pinterest"
                case .dribbble: return "Dribbble"
                case .brief: return "Brief"
                case .tutorial: return "Tutorial"
                case .other: return "Link"
                }
            }
        }

        public var id: UUID
        public var kind: Kind
        public var title: String
        public var url: String

        public init(id: UUID = UUID(), kind: Kind = .other, title: String = "", url: String) {
            self.id = id
            self.kind = kind
            self.title = title
            self.url = url
        }
    }

    public var kind: Kind
    /// Bundle IDs, the main one first.
    public var apps: [String]
    /// The main file(s): what clicking the easel opens.
    public var mainFiles: [String]
    public var links: [Link]
    /// The project's folder (inside an Orbit folder) and its bookmark.
    public var folder: String?
    public var folderBookmark: Data?
    /// Where exports go; nil means `<folder>/Exports`.
    public var exportsFolder: String?
    public var status: Status
    /// A picture to show for the project (else its latest export or file).
    public var coverImage: String?
    public var finishedAt: Date?
    public var isArchived: Bool

    public init(kind: Kind = .other, apps: [String] = [], mainFiles: [String] = [], links: [Link] = [], folder: String? = nil,
                folderBookmark: Data? = nil, exportsFolder: String? = nil, status: Status = .inProgress, coverImage: String? = nil,
                finishedAt: Date? = nil, isArchived: Bool = false) {
        self.kind = kind
        self.apps = apps
        self.mainFiles = mainFiles
        self.links = links
        self.folder = folder
        self.folderBookmark = folderBookmark
        self.exportsFolder = exportsFolder
        self.status = status
        self.coverImage = coverImage
        self.finishedAt = finishedAt
        self.isArchived = isArchived
    }

    /// The exports folder, defaulting to `<folder>/Exports`.
    public var resolvedExportsFolder: String? {
        exportsFolder ?? folder.map { ($0 as NSString).appendingPathComponent("Exports") }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        mainFiles = try c.decodeIfPresent([String].self, forKey: .mainFiles) ?? []
        links = try c.decodeIfPresent([Link].self, forKey: .links) ?? []
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        exportsFolder = try c.decodeIfPresent(String.self, forKey: .exportsFolder)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .inProgress
        coverImage = try c.decodeIfPresent(String.self, forKey: .coverImage)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

public struct ProjectLink: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    /// Opened or revealed when the project's Space activates.
    public var isKey: Bool
    /// The file was moved or deleted outside ATLAS.
    public var isBroken: Bool
    public var addedAt: Date

    public init(id: UUID = UUID(), path: String, isKey: Bool = false, isBroken: Bool = false, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.isKey = isKey
        self.isBroken = isBroken
        self.addedAt = addedAt
    }

    public var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Undo log

/// One file change ATLAS made, kept so it can be undone from Run History.
public struct FileOperation: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move, rename, copy, trash, createFolder, tag

        public var title: String {
            switch self {
            case .move: return "Moved"
            case .rename: return "Renamed"
            case .copy: return "Copied"
            case .trash: return "Moved to Trash"
            case .createFolder: return "Created folder"
            case .tag: return "Tagged"
            }
        }

        /// Copies and new folders aren't reversed: undoing them would mean
        /// removing something, and ATLAS only removes things you pick.
        public var isUndoable: Bool {
            switch self {
            case .move, .rename, .trash, .tag: return true
            case .copy, .createFolder: return false
            }
        }
    }

    public var id: UUID
    public var runID: UUID?
    public var kind: Kind
    public var source: String
    /// New path (move, rename, copy), or where it went in the Trash.
    public var destination: String?
    /// e.g. previous Finder tags.
    public var extra: [String: String]
    public var performedAt: Date
    public var undoneAt: Date?
    public var undoNote: String?
    /// Written as `pending` before the change and `done` after, so a change
    /// cut short by a crash or quit is found and settled on the next launch.
    public var state: State

    public enum State: String, Codable, Sendable {
        case pending, done
        /// Found half-done at launch and put back.
        case rolledBack
    }

    public init(id: UUID = UUID(), runID: UUID?, kind: Kind, source: String, destination: String? = nil,
                extra: [String: String] = [:], performedAt: Date = Date(), undoneAt: Date? = nil, undoNote: String? = nil,
                state: State = .done) {
        self.id = id
        self.state = state
        self.runID = runID
        self.kind = kind
        self.source = source
        self.destination = destination
        self.extra = extra
        self.performedAt = performedAt
        self.undoneAt = undoneAt
        self.undoNote = undoNote
    }

    public var summary: String {
        let name = (source as NSString).lastPathComponent
        switch kind {
        case .move: return "Moved \(name) to \(((destination ?? "") as NSString).deletingLastPathComponent.abbreviatedPath)"
        case .rename: return "Renamed \(name) to \(((destination ?? "") as NSString).lastPathComponent)"
        case .copy: return "Copied \(name) to \(((destination ?? "") as NSString).deletingLastPathComponent.abbreviatedPath)"
        case .trash: return "Moved \(name) to the Trash"
        case .createFolder: return "Created \(name)"
        case .tag: return "Tagged \(name): \(extra["tags"] ?? "")"
        }
    }
}

extension String {
    /// /Users/me/Downloads → ~/Downloads
    public var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Health

/// One reading of how the Mac is doing. Values a Mac can't report are nil.
public struct HealthSample: Hashable, Sendable {
    public var takenAt: Date
    /// Seconds this row covers: 5 for a raw reading, more once averaged.
    public var resolution: Int
    /// 0–100, all cores.
    public var cpu: Double
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    /// 0 normal, 1 warning, 2 critical.
    public var memoryPressure: Int
    public var diskFree: Int64
    public var diskTotal: Int64
    public var battery: Double?
    public var isCharging: Bool?

    public init(takenAt: Date = Date(), resolution: Int = 5, cpu: Double, memoryUsed: Int64, memoryTotal: Int64,
                memoryPressure: Int = 0, diskFree: Int64, diskTotal: Int64, battery: Double? = nil, isCharging: Bool? = nil) {
        self.takenAt = takenAt
        self.resolution = resolution
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryPressure = memoryPressure
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.battery = battery
        self.isCharging = isCharging
    }

    public var memoryPercent: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0 }
    public var diskUsedPercent: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) * 100 : 0 }
}

// MARK: - Events

extension AtlasEvent.Name {
    /// Payload: path, locationId (and oldPath for moves). Published by the Orbit indexer.
    public static let fileCreatedEvent = "file.created"
    public static let fileModifiedEvent = "file.modified"
    public static let fileMovedEvent = "file.moved"
    public static let fileDeletedEvent = "file.deleted"
    /// Payload: locationId, name, files, phase.
    public static let indexProgress = "index.progress"
    public static let indexCompleted = "index.completed"
    /// Payload: ruleId, ruleName, path.
    public static let ruleMatched = "rule.matched"
    /// Payload: reviewId, path, reason.
    public static let reviewAdded = "review.added"
    /// Payload: sets, recoverableBytes.
    public static let duplicatesFound = "duplicates.found"
    /// Payload: cpu, memoryPercent, diskFree, battery.
    public static let healthSample = "health.sample"
    /// Payload: metric, value, threshold, message.
    public static let healthThreshold = "health.threshold"
    /// Payload: operationId, runId. A file change was recorded or undone.
    public static let fileOperationLogged = "file.operation"
    /// An Orbit folder was added or removed, so what ATLAS may change did too.
    public static let fileAccessChanged = "file.access.changed"
}
