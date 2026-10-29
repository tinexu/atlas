import AtlasCore
import Foundation

/// PDFs in a course folder, for the Reading and Problem set profiles.
enum CoursePDFs {
    /// PDFs up to three folders deep, newest first.
    static func find(in folder: String, fileManager: FileManager = .default, limit: Int = 2_000) -> [(path: String, modified: Date)] {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(String, Date)] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            if walker.level > 3 { walker.skipDescendants() }
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append((url.path, modified))
        }
        return found.sorted { $0.1 > $1.1 }.map { (path: $0.0, modified: $0.1) }
    }

    /// The PDF whose name shares the most words with `title` ("Problem Set 4"
    /// → "ps4.pdf" doesn't, "Problem Set 4.pdf" does), else the newest.
    static func best(_ pdfs: [(path: String, modified: Date)], for title: String?) -> String? {
        guard let title else { return pdfs.first?.path }
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 || $0.first?.isNumber == true })
        }
        let wanted = words(title)
        let scored = pdfs.map { pdf in (pdf.path, words(((pdf.path as NSString).lastPathComponent as NSString).deletingPathExtension).intersection(wanted).count) }
        if let top = scored.max(by: { $0.1 < $1.1 }), top.1 > 0 { return top.0 }
        return pdfs.first?.path
    }
}

/// The bundle ID of the app a course's notes open in, when there is one
/// (for putting it on the right half).
private func notesApp(_ notes: Course.Notes) -> String? {
    switch notes {
    case .obsidian: return "md.obsidian"
    case .app(let bundleID, _): return bundleID
    case .folder: return "com.apple.finder"
    case .none, .url: return nil
    }
}

private func openNotesOnly(_ course: Course, service: StudyService, context: ActionContext) async throws -> Bool {
    service.courseOpened?(course.id)
    return try await OpenCourseAction.openNotes(course.notes, context: context)
}

/// `study.openDefault`: the Default profile. The course of the moment's
/// book (folder, notes, site) and a lo-fi playlist.
struct OpenDefaultStudyAction: AtlasAction {
    static let id: ActionID = "study.openDefault"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: OpenDefaultStudyAction.id, title: "Open Course of the Moment",
        summary: "Opens the course you're most likely on (a class now, the book you clicked, your last session) and your lo-fi playlist.",
        category: "Study", symbolName: "music.note.house",
        sideEffects: [.opensURL, .showsUI, .launchesApplication], isIdempotent: false, defaultTimeout: 30
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, sessions, _) = try context.require()
        var opened: [String] = []
        if let course = service.courseOfTheMoment(lastClicked: sessions.lastClickedCourse, recent: sessions.recentCourse()) {
            let output = try await OpenCourseAction(service: service).perform(["course": .string(course.id.uuidString)], context: actionContext)
            opened.append(output.message)
        }
        let playlist = service.settings.lofiPlaylist.trimmingCharacters(in: .whitespaces)
        if !playlist.isEmpty, let url = URL(string: playlist) {
            do {
                try await actionContext.system.open(url: url, withApplication: nil)
                opened.append("lo-fi playlist")
            } catch {
                opened.append("(the playlist didn't open: \(error.localizedDescription))")
            }
        }
        return ActionOutput(opened.isEmpty ? "Nothing to open yet: add a course" : opened.joined(separator: " · "))
    }
}

/// `study.openReading`: the Reading profile. The course's latest PDF on
/// the left half, its notes on the right.
struct OpenReadingAction: AtlasAction {
    static let id: ActionID = "study.openReading"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: OpenReadingAction.id, title: "Reading Layout",
        summary: "Opens the course of the moment's newest PDF on the left half of the screen and its notes on the right.",
        category: "Study", symbolName: "rectangle.split.2x1",
        sideEffects: [.opensURL, .showsUI, .launchesApplication, .arrangesWindows], isIdempotent: false, defaultTimeout: 60
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, sessions, _) = try context.require()
        guard let course = service.courseOfTheMoment(lastClicked: sessions.lastClickedCourse, recent: sessions.recentCourse()) else {
            return ActionOutput("Nothing to read yet: add a course")
        }
        let reader = service.settings.pdfReader
        var opened: [String] = []
        var notes: [String] = []
        if let folder = service.resolvedFolder(of: course), let pdf = CoursePDFs.find(in: folder).first?.path {
            try await actionContext.system.openFile(atPath: pdf, withApplication: reader)
            opened.append((pdf as NSString).lastPathComponent)
            notes.append(await context.arrange(reader, .leftHalf))
        }
        if try await openNotesOnly(course, service: service, context: actionContext), let app = notesApp(course.notes) {
            opened.append("\(course.displayCode) notes")
            notes.append(await context.arrange(app, .rightHalf))
        }
        let problems = notes.filter { !$0.isEmpty }
        if opened.isEmpty { return ActionOutput("\(course.displayCode): no PDF in its folder and no notes on this Mac") }
        var output = ActionOutput("\(course.displayCode): " + opened.joined(separator: ", "))
        if !problems.isEmpty { output.partialFailure = problems.joined(separator: "; ") }
        return output
    }
}

/// `study.openProblemSet`: the Problem set profile. The next assignment's
/// PDF, the course's notes and a calculator.
struct OpenProblemSetAction: AtlasAction {
    static let id: ActionID = "study.openProblemSet"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: OpenProblemSetAction.id, title: "Problem Set",
        summary: "Opens the next assignment's PDF (the best match in its course folder), the course's notes and a calculator (Desmos by default).",
        category: "Study", symbolName: "function",
        sideEffects: [.opensURL, .showsUI, .launchesApplication], isIdempotent: false, defaultTimeout: 30
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, sessions, assignments) = try context.require()
        let next = assignments.nextDeadline()
        let course = next?.courseID.flatMap { service.course(id: $0) }
            ?? service.courseOfTheMoment(lastClicked: sessions.lastClickedCourse, recent: sessions.recentCourse())
        var opened: [String] = []
        if let course {
            if let folder = service.resolvedFolder(of: course), let pdf = CoursePDFs.best(CoursePDFs.find(in: folder), for: next?.title) {
                try await actionContext.system.openFile(atPath: pdf, withApplication: service.settings.pdfReader)
                opened.append((pdf as NSString).lastPathComponent)
            }
            if try await openNotesOnly(course, service: service, context: actionContext) { opened.append("\(course.displayCode) notes") }
        }
        let calculator = service.settings.calculator.trimmingCharacters(in: .whitespaces)
        if calculator.hasPrefix("http"), let url = URL(string: calculator) {
            try await actionContext.system.open(url: url, withApplication: nil)
            opened.append("calculator")
        } else if !calculator.isEmpty {
            _ = try await actionContext.system.launchApplication(bundleID: calculator, activate: true)
            opened.append("calculator")
        }
        let what = next.map { "\($0.title): " } ?? ""
        return ActionOutput(what + (opened.isEmpty ? "nothing to open" : opened.joined(separator: ", ")))
    }
}
