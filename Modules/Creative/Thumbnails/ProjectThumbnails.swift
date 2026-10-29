import AppKit
import AtlasCore
import CoreImage
import Foundation
import QuickLookThumbnailing

/// Makes a picture of a file; QuickLook in the app, a stand-in in tests.
public protocol ThumbnailMaking: Sendable {
    func thumbnail(of path: String, size: CGFloat) async -> CGImage?
}

public struct QuickLookThumbnails: ThumbnailMaking {
    public init() {}

    public func thumbnail(of path: String, size: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                   scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// Small pictures of project files (at most 512 px), made in the
/// background and cached on disk by path and modification date, so a file
/// that changes gets a new picture and an unchanged one costs nothing.
/// Each comes with a blurred copy for the monitor.
public final class ProjectThumbnails: @unchecked Sendable {
    public static let size: CGFloat = 512

    let folder: URL
    let maker: ThumbnailMaking
    private let lock = NSLock()
    private var pending: Set<String> = []
    /// Files QuickLook can't draw (e.g. some .blend files): not asked again until they change.
    private var failed: Set<String> = []

    public init(folder: URL? = nil, maker: ThumbnailMaking = QuickLookThumbnails()) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATLAS/Thumbnails", isDirectory: true)
        self.maker = maker
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    /// The cached picture of `path` (or its blurred copy), if made already.
    public func cached(_ path: String, blurred: Bool = false) -> String? {
        guard let key = key(for: path) else { return nil }
        let file = folder.appendingPathComponent(key + (blurred ? "-blur" : "") + ".png").path
        return FileManager.default.fileExists(atPath: file) ? file : nil
    }

    /// Makes the picture if it isn't cached. True if a new one was made.
    @discardableResult
    public func make(_ path: String) async -> Bool {
        guard let key = key(for: path), cached(path) == nil else { return false }
        let busy = lock.withLock { () -> Bool in
            guard !pending.contains(key), !failed.contains(key) else { return true }
            pending.insert(key)
            return false
        }
        guard !busy else { return false }
        defer { lock.withLock { _ = pending.remove(key) } }
        guard let image = await maker.thumbnail(of: path, size: Self.size) else {
            lock.withLock { _ = failed.insert(key) }
            return false
        }
        let plain = folder.appendingPathComponent(key + ".png")
        let blurred = folder.appendingPathComponent(key + "-blur.png")
        guard Self.writePNG(image, to: plain) else { return false }
        if let soft = Self.blurred(image) { _ = Self.writePNG(soft, to: blurred) }
        return true
    }

    /// Path and modification date, hashed.
    private func key(for path: String) -> String? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let text = "\(path)|\(Int(modified.timeIntervalSince1970))"
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(18, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
