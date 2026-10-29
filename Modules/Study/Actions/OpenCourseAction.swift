import AtlasCore
import Foundation

/// `study.openCourse`: what clicking a course's book does. Opens its
/// folder in Finder, its notes and its course site, each only if that's
/// switched on for the course.
public struct OpenCourseAction: AtlasAction {
    public static let id: ActionID = "study.openCourse"
    final class Ref: @unchecked Sendable { weak var service: StudyService? }
    let ref = Ref()

    public let descriptor = ActionDescriptor(
        id: OpenCourseAction.id,
        title: "Open Course",
        summary: "Opens a course's folder in Finder, its notes and its course site (whichever are switched on for it).",
        category: "Study",
        symbolName: "book.closed",
        parameters: [ParameterSpec(key: "course", label: "Course", kind: .text, help: "Course code or name, e.g. CHEM101")],
        sideEffects: [.opensURL, .showsUI],
        isIdempotent: false,
        defaultTimeout: 20
    )

    init(service: StudyService) {
        ref.service = service
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let service = ref.service else { throw ActionError.failed("The Study Library isn't available right now.") }
        let reference = try parameters.requiredString("course")
        guard let course = service.course(reference: reference) else {
            throw ActionError.invalidParameter("Course", reason: "no course is called “\(reference)”.")
        }
        service.courseOpened?(course.id)
        var opened: [String] = []
        var problems: [String] = []
        if course.opens.folder {
            if let folder = service.resolvedFolder(of: course) {
                do {
                    try await context.system.openFile(atPath: (folder as NSString).expandingTildeInPath, withApplication: "com.apple.finder")
                    opened.append("folder")
                } catch {
                    problems.append("its folder (\(error.localizedDescription))")
                }
            }
        }
        if course.opens.notes {
            do {
                if try await Self.openNotes(course.notes, context: context) { opened.append("notes") }
            } catch {
                problems.append("its notes (\(error.localizedDescription))")
            }
        }
        if course.opens.site, let site = course.site, let url = URL(string: site.url) {
            do {
                try await context.system.open(url: url, withApplication: nil)
                opened.append("site")
            } catch {
                problems.append("its site (\(error.localizedDescription))")
            }
        }
        if opened.isEmpty, !problems.isEmpty {
            throw ActionError.failed("Couldn't open \(course.displayCode): \(problems.joined(separator: "; ")).")
        }
        let what = opened.isEmpty ? "nothing to open yet; add a folder, notes or site in Courses" : opened.joined(separator: ", ")
        return ActionOutput("\(course.displayCode): \(what)", values: ["course": .string(course.code)])
    }

    /// Opens a course's notes. Returns whether anything was opened.
    static func openNotes(_ notes: Course.Notes, context: ActionContext) async throws -> Bool {
        switch notes {
        case .none:
            return false
        case .folder(let path):
            try await context.system.openFile(atPath: (path as NSString).expandingTildeInPath, withApplication: nil)
        case .obsidian(let vault, let relative):
            var components = URLComponents()
            components.scheme = "obsidian"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "vault", value: (vault as NSString).lastPathComponent),
                                     URLQueryItem(name: "file", value: relative)]
            guard let url = components.url else { return false }
            try await context.system.open(url: url, withApplication: nil)
        case .app(let bundleID, _):
            _ = try await context.system.launchApplication(bundleID: bundleID, activate: true)
        case .url(let raw):
            guard let url = URL(string: raw) else { return false }
            try await context.system.open(url: url, withApplication: nil)
        }
        return true
    }
}
