import AtlasCore
import Foundation

/// The creative file types ATLAS recognizes: what kind of work each is and
/// which apps open it (in preference order; only installed ones are used).
public enum CreativeFiles {
    public struct FileType: Sendable {
        public let kind: CreativeInfo.Kind
        public let apps: [String]
    }

    public static let types: [String: FileType] = [
        "blend": .init(kind: .threeD, apps: ["org.blenderfoundation.blender"]),
        "f3d": .init(kind: .threeD, apps: []),
        "f3z": .init(kind: .threeD, apps: []),
        "c4d": .init(kind: .threeD, apps: ["com.maxon.cinema4d"]),
        "afdesign": .init(kind: .design, apps: ["com.seriflabs.affinitydesigner2", "com.seriflabs.affinitydesigner"]),
        "afpub": .init(kind: .design, apps: ["com.seriflabs.affinitypublisher2", "com.seriflabs.affinitypublisher"]),
        "afphoto": .init(kind: .photo, apps: ["com.seriflabs.affinityphoto2", "com.seriflabs.affinityphoto"]),
        "psd": .init(kind: .photo, apps: ["com.adobe.Photoshop"]),
        "ai": .init(kind: .illustration, apps: ["com.adobe.illustrator"]),
        "sketch": .init(kind: .design, apps: ["com.bohemiancoding.sketch3"]),
        "fig": .init(kind: .design, apps: ["com.figma.Desktop"]),
        "xd": .init(kind: .design, apps: ["com.adobe.xd"]),
        "procreate": .init(kind: .illustration, apps: []),
        "kra": .init(kind: .illustration, apps: ["org.krita"]),
        "clip": .init(kind: .illustration, apps: ["jp.co.celsys.CLIPSTUDIOPAINT"]),
        "pxd": .init(kind: .photo, apps: ["com.pixelmatorteam.pixelmator.x"]),
        "lrcat": .init(kind: .photo, apps: ["com.adobe.LightroomClassicCC7"]),
        "aep": .init(kind: .video, apps: ["com.adobe.AfterEffects"]),
        "prproj": .init(kind: .video, apps: ["com.adobe.PremierePro"]),
        "fcpbundle": .init(kind: .video, apps: ["com.apple.FinalCut"]),
        "imovielibrary": .init(kind: .video, apps: ["com.apple.iMovieApp"]),
        "drp": .init(kind: .video, apps: ["com.blackmagic-design.DaVinciResolve"]),
    ]

    /// Exports and pictures (what the easel can show, besides the main file).
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "svg", "pdf", "bmp"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    /// Subfolders that belong to a project rather than being one.
    public static let projectSubfolders: Set<String> = ["versions", "exports", "export", "references", "refs", "renders", "render",
                                                        "assets", "backup", "backups", "output", "textures"]

    public static func type(of path: String) -> FileType? {
        types[(path as NSString).pathExtension.lowercased()]
    }

    /// The design app to fall back on: Figma, Affinity Designer, Sketch,
    /// Photoshop, Blender, whichever is installed first; else Preview.
    public static func defaultDesignApp(isInstalled: (String) -> Bool) -> String {
        ["com.figma.Desktop", "com.seriflabs.affinitydesigner2", "com.bohemiancoding.sketch3", "com.adobe.Photoshop",
         "org.blenderfoundation.blender"].first(where: isInstalled) ?? "com.apple.Preview"
    }
}
