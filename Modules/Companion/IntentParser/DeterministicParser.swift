import AtlasCore
import AtlasSpaces
import Foundation

/// Understands short commands without any AI: a fixed set of verbs and
/// synonyms, plus fuzzy matching of what follows against your Spaces,
/// workflows, apps, layouts and snapshots. Always on, and the fallback when
/// AI is off or fails.
///
/// "Open my coding room" → Activate Coding Lab
/// "Run my morning setup" → Run Morning Setup
/// "Find my project specifications" → files matching "project specifications"
/// "Start my study timer" → Start a 25 min "Study" timer
/// "Arrange my windows for an interview" → the Interview layout
/// "Show me what's taking up storage" → Orbit's largest files
public struct DeterministicParser: Sendable {
    public let vocabulary: CommandVocabulary

    public init(vocabulary: CommandVocabulary) {
        self.vocabulary = vocabulary
    }

    enum Verb: String, CaseIterable {
        case activate, run, open, find, arrange, restore, pause, resume, stop, quit, save

        /// Phrases, longest first so "switch to" wins over "switch".
        var phrases: [String] {
            switch self {
            case .activate: return ["switch to", "go to", "change to", "take me to", "activate", "enter", "switch", "load"]
            case .run: return ["run", "execute", "trigger", "do"]
            case .open: return ["open up", "open", "launch", "start", "begin", "bring up", "show"]
            case .find: return ["search for", "look for", "where is", "where are", "wheres", "show me", "find", "search", "locate"]
            case .arrange: return ["lay out", "arrange", "layout", "organize", "organise", "tidy", "set up windows", "apply"]
            case .restore: return ["bring back", "restore", "reopen", "go back to"]
            case .pause: return ["pause", "hold", "suspend", "turn off automations", "disable automations"]
            case .resume: return ["resume", "unpause", "continue", "turn on automations", "enable automations"]
            case .stop: return ["cancel", "stop", "kill", "end", "abort"]
            case .quit: return ["quit", "close", "exit"]
            case .save: return ["save", "capture", "remember", "take"]
            }
        }
    }

    /// Words that hint at a kind of thing without being part of its name.
    static let spaceWords: Set<String> = ["room", "rooms", "space", "spaces", "world", "mode", "workspace"]
    static let appWords: Set<String> = ["app", "application"]
    static let workflowWords: Set<String> = ["workflow", "automation", "routine", "shortcut"]
    static let layoutWords: Set<String> = ["windows", "window", "layout", "layouts", "screen", "screens"]

    public func parse(_ raw: String) -> ParseOutcome {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return .unknown("Type a command, like “open my coding room”.") }
        let (verb, rest) = Self.splitVerb(text)

        if let plan = storagePlan(text) { return .plan(plan) }
        if let outcome = workSessionPlan(text) { return outcome }
        if let plan = automationIdea(raw: raw, text: text) { return .plan(plan) }
        if let plan = focusControl(text) { return .plan(plan) }
        if verb == .pause || text == "pause automations" { return .plan(pausePlan(true)) }
        if verb == .resume { return .plan(pausePlan(false)) }
        if NameMatcher.words(text).contains("timer") { return timerPlan(verb: verb, rest: rest, text: text) }
        if let screen = screenPlan(text: text, verb: verb, rest: rest) { return .plan(screen) }

        switch verb {
        case .find:
            return findPlan(rest)
        case .arrange:
            return layoutPlan(rest)
        case .restore:
            return restorePlan(rest)
        case .stop:
            return stopPlan(rest)
        case .quit:
            return quitPlan(rest)
        case .save where NameMatcher.words(rest).contains(where: { $0.hasPrefix("snapshot") || $0 == "session" }):
            return .plan(snapshotSavePlan(rest))
        case .activate, .run, .open, .save, .none, .pause, .resume:
            break
        }
        // "open my interview layout", "windows for coding"
        if verb != .activate, verb != .run, NameMatcher.words(rest).contains(where: { $0 == "windows" || $0 == "layout" }) {
            return layoutPlan(rest)
        }
        return targetPlan(verb: verb, rest: rest)
    }

    // MARK: - Text

    /// Lowercased, punctuation trimmed, politeness and "hey atlas" removed.
    static func clean(_ text: String) -> String {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        t = t.replacingOccurrences(of: "’", with: "'")
        for prefix in ["hey atlas", "ok atlas", "atlas", "please", "can you", "could you", "would you", "i want to", "i'd like to",
                       "i need to", "let's", "lets", "help me"] {
            if t.hasPrefix(prefix + " ") { t = String(t.dropFirst(prefix.count + 1)) }
            if t.hasPrefix(prefix + ",") { t = String(t.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        if t.hasSuffix(" please") { t = String(t.dropLast(7)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The command's verb (tolerating one typo in a single-word verb) and the rest.
    static func splitVerb(_ text: String) -> (Verb?, String) {
        var best: (verb: Verb, phrase: String)?
        for verb in Verb.allCases {
            for phrase in verb.phrases where text == phrase || text.hasPrefix(phrase + " ") {
                if phrase.count > (best?.phrase.count ?? 0) { best = (verb, phrase) }
            }
        }
        if let best {
            return (best.verb, String(text.dropFirst(best.phrase.count)).trimmingCharacters(in: .whitespaces))
        }
        // "opne my coding room", "swtich to …"
        let first = NameMatcher.words(text).first ?? ""
        if first.count >= 4 {
            for verb in Verb.allCases {
                for phrase in verb.phrases where !phrase.contains(" ") && phrase.count >= 4 && NameMatcher.levenshtein(first, phrase) == 1 {
                    let rest = text.drop { $0 != " " }
                    return (verb, rest.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return (nil, text)
    }

    // MARK: - Fixed commands

    func storagePlan(_ text: String) -> CommandPlan? {
        let phrases = ["taking up storage", "taking up space", "using storage", "using space", "using my disk", "storage",
                       "disk space", "largest files", "biggest files", "large files", "big files", "free up space", "space hogs"]
        guard phrases.contains(where: text.contains) else { return nil }
        if text.contains("clean") || text.contains("free up") {
            return CommandPlan(kind: .open(.cleanup), summary: "Open Cleanup Review", details: ["Suggestions for freeing space. Nothing is deleted until you confirm."],
                               hasSideEffects: false, subject: "Cleanup Review")
        }
        return CommandPlan(kind: .open(.largestFiles), summary: "Show the largest files in Orbit",
                           details: ["Opens Orbit's file browser sorted by size, across the folders you added."],
                           hasSideEffects: false, subject: "Largest files")
    }

    public func pausePlan(_ paused: Bool) -> CommandPlan {
        CommandPlan(kind: .pauseAutomations(paused), summary: paused ? "Pause all automations" : "Resume automations",
                    details: [paused ? "Triggers stop starting runs until you resume. Runs in progress finish." : "Triggers start runs again."],
                    hasSideEffects: true, subject: paused ? "Pause" : "Resume")
    }

    func screenPlan(text: String, verb: Verb?, rest: String) -> CommandPlan? {
        guard verb == nil || verb == .open || verb == .activate || verb == .find else { return nil }
        let target = NameMatcher.keywords(rest).joined(separator: " ")
        let screens: [(words: [String], destination: CommandPlan.Destination, title: String)] = [
            (["companion settings", "companion"], .companionSettings, "Companion settings"),
            (["today", "my day", "daily overview"], .today, "Today"),
            (["time architect", "timeline", "calendar", "schedule"], .timeline, "Time Architect"),
            (["permissions", "privacy"], .section("permissions"), "Permissions"),
            (["run history", "history", "runs", "log"], .runHistory(nil), "Run History"),
            (["automations", "workflows", "flow"], .section("automations"), "Automations"),
            (["review queue", "reviews", "review"], .reviewQueue, "the review queue"),
            (["mac health", "health", "system health", "battery", "cpu"], .health, "Mac Health"),
            (["orbit", "files", "file universe"], .section("orbit"), "Orbit"),
            (["settings", "preferences"], .companionSettings, "Companion settings"),
            (["spaces", "mission control"], .section("spaces"), "Spaces"),
            (["window manager", "windows manager"], .section("windows"), "the Window Manager"),
        ]
        for screen in screens where screen.words.contains(target) {
            return CommandPlan(kind: .open(screen.destination), summary: "Open \(screen.title)", hasSideEffects: false, subject: screen.title)
        }
        return nil
    }

    // MARK: - Automations and focus

    /// "When I open Blender, activate Creative Studio" describes an automation.
    func automationIdea(raw: String, text: String) -> CommandPlan? {
        let starts = ["when i ", "whenever i ", "when a ", "when my ", "every weekday", "every day", "every morning", "each time i ", "every time i "]
        guard starts.contains(where: text.hasPrefix), text.split(separator: " ").count >= 4 else { return nil }
        return CommandPlan(kind: .open(.describeAutomation(raw.trimmingCharacters(in: .whitespacesAndNewlines))),
                           summary: "Draft an automation: “\(raw.trimmingCharacters(in: .whitespacesAndNewlines))”",
                           details: ["Opens a draft in Automations to review. Nothing is saved or turned on until you say so."],
                           hasSideEffects: false, subject: "Automation")
    }

    /// "pause focus", "stop focus", "end my focus session".
    func focusControl(_ text: String) -> CommandPlan? {
        let words = Set(NameMatcher.words(text))
        guard words.contains("focus") else { return nil }
        if !words.isDisjoint(with: ["stop", "end", "cancel", "finish"]) {
            return CommandPlan(kind: .actions([.init(StopFocusAction.id)]), summary: "Stop the focus session", hasSideEffects: true, subject: "Focus")
        }
        if words.contains("plan") || words.contains("timeline") || words.contains("schedule") {
            return CommandPlan(kind: .open(.timeline), summary: "Open Time Architect", hasSideEffects: false, subject: "Time Architect")
        }
        return nil
    }

    // MARK: - Work sessions

    /// What a Space is for, by template, to match "my app" or "my essay".
    static let spaceHints: [String: Set<String>] = [
        "coding-lab": ["code", "coding", "app", "apps", "program", "programming", "develop", "developing", "project", "software", "bug",
                       "bugs", "website", "api", "repo"],
        "study-library": ["study", "studying", "homework", "exam", "exams", "class", "course", "reading", "revise", "revision", "essay",
                          "thesis", "notes", "lecture"],
        "creative-studio": ["design", "art", "draw", "drawing", "blender", "video", "music", "creative", "edit", "editing", "photo",
                            "photos", "illustration", "animation"],
        "meeting-room": ["meeting", "meetings", "call", "calls", "interview"],
        "personal-lounge": ["relax", "personal", "games", "gaming"],
    ]

    /// "I'm going to work on my app for the next two hours", "focus on my
    /// essay for 90 minutes", "study for an hour": the right Space plus a
    /// focus block of that length on the timeline.
    func workSessionPlan(_ text: String) -> ParseOutcome? {
        let normalized = Self.wordsToNumbers(text)
        let pattern = #"^(?:i'm |i am |im )?(?:going to |gonna |about to |want to |will )?(work|study|focus|design|write|code|practice|read)(?:ing)?(?: on)? ?(.*?) for (?:the next |about |around )?(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let verbRange = Range(match.range(at: 1), in: normalized), let topicRange = Range(match.range(at: 2), in: normalized),
              let durationRange = Range(match.range(at: 3), in: normalized),
              let seconds = Self.duration(in: String(normalized[durationRange])), seconds >= 5 * 60
        else { return nil }
        let verb = String(normalized[verbRange])
        let topic = String(normalized[topicRange]).trimmingCharacters(in: .whitespaces)
        let words = Set(NameMatcher.keywords(topic + " " + verb))
        // A Space named in the topic, else one whose purpose fits.
        let named = NameMatcher.rank(topic, in: vocabulary.spaces, name: \.name, ignoring: Self.spaceWords).first.flatMap { $0.score >= 0.75 ? $0.item : nil }
        let space = named ?? vocabulary.spaces.first { space in
            !(Self.spaceHints[space.templateID] ?? []).isDisjoint(with: words)
        }
        let minutes = seconds / 60
        let title = topic.isEmpty ? verb.capitalized : topic.replacingOccurrences(of: "^(my|the|a) ", with: "", options: .regularExpression).capitalized
        var focus: ActionParameters = ["minutes": .number(minutes), "title": .string(space?.defaultProfile?.name ?? title)]
        if let space { focus["space"] = .string(space.name) }
        var steps: [CommandPlan.Step] = []
        if let space { steps.append(.init(SpaceActivateAction.id, ["space": .string(space.name)])) }
        steps.append(.init(StartFocusAction.id, focus))
        let length = StartTimerAction.duration(seconds)
        let summary = space.map { "Activate \($0.name)\($0.defaultProfile.map { " — \($0.name)" } ?? "") and start a \(length) focus block" }
            ?? "Start a \(length) focus block for “\(title)”"
        return .plan(CommandPlan(kind: .actions(steps), summary: summary,
                                 details: ["The block appears on your Time Architect timeline and counts down in the menu bar."]
                                    + (space == nil ? ["No Space matched “\(topic)”, so only the timer starts."] : []),
                                 hasSideEffects: true, subject: space?.name ?? title))
    }

    /// "two hours" → "2 hours".
    static func wordsToNumbers(_ text: String) -> String {
        let numbers = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
                       "nine": "9", "ten": "10", "fifteen": "15", "twenty": "20", "thirty": "30", "forty": "40", "forty-five": "45",
                       "fifty": "50", "sixty": "60", "ninety": "90"]
        return text.split(separator: " ").map { numbers[String($0)] ?? String($0) }.joined(separator: " ")
    }

    // MARK: - Timers

    func timerPlan(verb: Verb?, rest: String, text: String) -> ParseOutcome {
        // A workflow literally named for it wins ("Study Timer").
        let named = NameMatcher.keywords(rest, ignoring: ["start", "set", "begin"]).joined(separator: " ")
        if let match = NameMatcher.rank(named, in: vocabulary.workflows, name: \.name).first, match.score >= 0.8,
           let id = UUID(uuidString: match.item.id) {
            return .plan(workflowPlan(id: id, name: match.item.name))
        }
        let seconds = Self.duration(in: text)
        let ignore: Set<String> = ["timer", "start", "set", "begin", "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs",
                                   "second", "seconds", "sec", "secs", "and", "half", "one", "stop", "cancel", "end", "with"]
        // Drop the length ("25", "25m", "10min") and timer words; what's left names it.
        let nameWords = NameMatcher.keywords(rest).filter { !ignore.contains($0) && $0.allSatisfy(\.isLetter) }
        let name = nameWords.isEmpty ? "Timer" : nameWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")

        if verb == .stop {
            let running = vocabulary.timers
            let target = nameWords.isEmpty ? running.first : (NameMatcher.rank(name, in: running, name: { $0 }).first?.item ?? name)
            guard let target else { return .unknown("No timer is running.") }
            return .plan(CommandPlan(kind: .actions([.init(StopTimerAction.id, ["name": .string(target)])]),
                                     summary: "Stop the “\(target)” timer", hasSideEffects: true, subject: target))
        }
        let length = seconds ?? Self.defaultTimerLength(for: name)
        return .plan(CommandPlan(
            kind: .actions([.init(StartTimerAction.id, ["name": .string(name), "seconds": .number(length)])]),
            summary: "Start a \(StartTimerAction.duration(length)) “\(name)” timer",
            details: seconds == nil ? ["Say “for 50 minutes” to choose the length."] : [],
            hasSideEffects: true, subject: name
        ))
    }

    static func defaultTimerLength(for name: String) -> Double {
        let lower = name.lowercased()
        if lower.contains("break") || lower.contains("rest") { return 5 * 60 }
        if ["study", "focus", "work", "pomodoro", "deep", "write", "read"].contains(where: lower.contains) { return 25 * 60 }
        return 10 * 60
    }

    /// "25 minutes", "1 hour", "90s", "an hour and a half", "half an hour".
    static func duration(in text: String) -> Double? {
        if text.contains("half an hour") || text.contains("half hour") { return 1_800 }
        if text.contains("an hour and a half") { return 5_400 }
        if text.contains(" an hour") || text.hasPrefix("an hour") || text.contains("one hour") { return 3_600 }
        let pattern = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var total = 0.0
        for match in regex.matches(in: text, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[numberRange]) else { continue }
            let unit = text[unitRange]
            if unit.hasPrefix("h") { total += value * 3_600 }
            else if unit.hasPrefix("m") { total += value * 60 }
            else { total += value }
        }
        return total > 0 ? min(total, 86_400) : nil
    }

    // MARK: - Files

    func findPlan(_ rest: String) -> ParseOutcome {
        let words = NameMatcher.keywords(rest, ignoring: ["file", "files", "document", "documents", "doc", "docs", "called", "named"])
        guard !words.isEmpty else { return .unknown("What should I look for? Try “find my project specifications”.") }
        let query = words.joined(separator: " ")
        return .plan(CommandPlan(kind: .findFiles(query), summary: "Find files matching “\(query)”",
                                 details: ["Searches the folders you added to Orbit."], hasSideEffects: false, subject: query))
    }

    // MARK: - Windows

    func layoutPlan(_ rest: String) -> ParseOutcome {
        let ignore = Self.layoutWords.union(["arrange", "set", "up", "apply", "use", "get", "ready", "an", "a", "like"])
        let query = NameMatcher.keywords(rest, ignoring: ignore).joined(separator: " ")
        if !query.isEmpty {
            let layouts = NameMatcher.rank(query, in: vocabulary.layouts, name: \.name)
            if let outcome = pick(layouts.map { (plan: layoutApplyPlan($0.item.name), score: $0.score) }, prompt: "Which layout?") {
                return outcome
            }
            let snapshots = NameMatcher.rank(query, in: vocabulary.snapshots, name: \.name)
            if let best = snapshots.first { return .plan(snapshotRestorePlan(best.item.name)) }
        }
        let available = vocabulary.layouts.map(\.name)
        let subject = query.isEmpty ? "" : " matches “\(query)”"
        if available.isEmpty {
            return .unknown("No window layout\(subject). You haven't saved any layouts yet: arrange your windows, then capture a layout in the Window Manager (or say “save snapshot”).")
        }
        return .unknown("No window layout\(subject). Saved layouts: \(available.joined(separator: ", ")).")
    }

    public func layoutApplyPlan(_ name: String) -> CommandPlan {
        CommandPlan(kind: .actions([.init(ApplyWindowLayoutAction.id, ["layout": .string(name)])]),
                    summary: "Arrange windows: \(name) layout", details: ["Opens any apps it needs, then moves their windows."],
                    hasSideEffects: true, subject: name)
    }

    func restorePlan(_ rest: String) -> ParseOutcome {
        let query = NameMatcher.keywords(rest, ignoring: ["snapshot", "session", "windows", "where", "left", "off", "last"]).joined(separator: " ")
        if query.isEmpty, let latest = vocabulary.snapshots.first {
            return .plan(snapshotRestorePlan(latest.name))
        }
        let snapshots = NameMatcher.rank(query, in: vocabulary.snapshots, name: \.name)
        if let outcome = pick(snapshots.map { (plan: snapshotRestorePlan($0.item.name), score: $0.score) }, prompt: "Which snapshot?") {
            return outcome
        }
        let layouts = NameMatcher.rank(query, in: vocabulary.layouts, name: \.name)
        if let best = layouts.first { return .plan(layoutApplyPlan(best.item.name)) }
        return .unknown(vocabulary.snapshots.isEmpty
                        ? "There are no snapshots to restore yet. Say “save snapshot” to make one."
                        : "No snapshot matches “\(query)”.")
    }

    public func snapshotRestorePlan(_ name: String) -> CommandPlan {
        CommandPlan(kind: .actions([.init(RestoreSnapshotAction.id, ["snapshot": .string(name)])]),
                    summary: "Restore snapshot “\(name)”", details: ["Reopens its apps and puts windows back. Unsaved content inside apps can't be restored."],
                    hasSideEffects: true, subject: name)
    }

    public func snapshotSavePlan(_ rest: String) -> CommandPlan {
        let name = NameMatcher.keywords(rest, ignoring: ["snapshot", "session", "windows", "a", "called", "named", "as"])
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        var parameters: ActionParameters = [:]
        if !name.isEmpty { parameters["name"] = .string(name) }
        return CommandPlan(kind: .actions([.init(SaveSnapshotAction.id, parameters)]),
                           summary: name.isEmpty ? "Save a session snapshot" : "Save snapshot “\(name)”",
                           details: ["Remembers every window and running app."], hasSideEffects: true, subject: name.isEmpty ? "Snapshot" : name)
    }

    // MARK: - Stop / quit

    func stopPlan(_ rest: String) -> ParseOutcome {
        let words = NameMatcher.keywords(rest)
        if words.isEmpty || words == ["everything"] || words == ["all"] || words.contains("everything") {
            guard !vocabulary.runningWorkflows.isEmpty else { return .unknown("Nothing is running right now.") }
            return .plan(CommandPlan(kind: .stopRun(nil), summary: "Stop everything that's running",
                                     details: vocabulary.runningWorkflows.map(\.name), hasSideEffects: true, subject: "All runs"))
        }
        let query = words.joined(separator: " ")
        let running = NameMatcher.rank(query, in: vocabulary.runningWorkflows, name: \.name)
        if let best = running.first, let runID = UUID(uuidString: best.item.id) {
            return .plan(CommandPlan(kind: .stopRun(runID), summary: "Stop “\(best.item.name)”", hasSideEffects: true, subject: best.item.name))
        }
        if let timer = NameMatcher.rank(query, in: vocabulary.timers, name: { $0 }).first {
            return .plan(CommandPlan(kind: .actions([.init(StopTimerAction.id, ["name": .string(timer.item)])]),
                                     summary: "Stop the “\(timer.item)” timer", hasSideEffects: true, subject: timer.item))
        }
        if let app = NameMatcher.rank(query, in: vocabulary.apps, name: \.name, ignoring: Self.appWords).first {
            return .plan(quitAppPlan(app.item))
        }
        return .unknown("Nothing called “\(query)” is running.")
    }

    func quitPlan(_ rest: String) -> ParseOutcome {
        let query = NameMatcher.keywords(rest, ignoring: Self.appWords).joined(separator: " ")
        let apps = NameMatcher.rank(query, in: vocabulary.apps, name: \.name)
        if let outcome = pick(apps.map { (plan: quitAppPlan($0.item), score: $0.score) }, prompt: "Which app?") { return outcome }
        return .unknown(query.isEmpty ? "Which app should I quit?" : "No installed app matches “\(query)”.")
    }

    public func quitAppPlan(_ app: CommandVocabulary.Named) -> CommandPlan {
        CommandPlan(kind: .actions([.init(QuitApplicationAction.id, ["bundleId": .string(app.id)])]),
                    summary: "Quit \(app.name)", details: ["Unsaved work may prompt you to save."], hasSideEffects: true, subject: app.name)
    }

    // MARK: - Spaces, workflows, apps

    /// "open my coding room", "run morning setup", "coding lab", "launch safari".
    func targetPlan(verb: Verb?, rest: String) -> ParseOutcome {
        let words = Set(NameMatcher.words(rest))
        let ignore = Self.spaceWords.union(Self.appWords).union(Self.workflowWords)
        let query = NameMatcher.keywords(rest, ignoring: ignore).joined(separator: " ")
        guard !query.isEmpty else {
            return .unknown(verb == nil ? "Try “open my coding room” or “run morning setup”." : "Open what? Name a Space, workflow or app.")
        }

        var candidates: [(plan: CommandPlan, score: Double, key: String)] = []
        let wantsSpace = !words.isDisjoint(with: Self.spaceWords) || verb == .activate
        let wantsApp = !words.isDisjoint(with: Self.appWords)
        let wantsWorkflow = !words.isDisjoint(with: Self.workflowWords) || verb == .run

        for space in vocabulary.spaces {
            // "coding lab quick review" names a profile too.
            for (profileQuery, profile) in profileVariants(query, space) {
                let s = NameMatcher.score(query: profileQuery, name: space.name)
                guard s >= NameMatcher.threshold else { continue }
                let bonus = (wantsSpace ? 0.12 : 0) - (wantsApp || wantsWorkflow ? 0.1 : 0) + (profile != nil && profileQuery != query ? 0.02 : 0)
                candidates.append((spacePlan(space, profile: profile), s + bonus, "space:\(space.id)"))
            }
        }
        if verb != .activate {
            for workflow in vocabulary.workflows {
                let s = NameMatcher.score(query: query, name: workflow.name)
                guard s >= NameMatcher.threshold, let id = UUID(uuidString: workflow.id) else { continue }
                let bonus = (wantsWorkflow ? 0.12 : 0) - (wantsSpace || wantsApp ? 0.1 : 0)
                candidates.append((workflowPlan(id: id, name: workflow.name), s + bonus, "workflow:\(id)"))
            }
            for app in vocabulary.apps {
                let s = NameMatcher.score(query: query, name: app.name)
                guard s >= NameMatcher.threshold else { continue }
                let bonus = (wantsApp ? 0.12 : 0) - (wantsSpace || wantsWorkflow ? 0.1 : 0) - (verb == .run ? 0.1 : 0)
                candidates.append((launchAppPlan(app), s + bonus, "app:\(app.id)"))
            }
        }
        // Keep each thing once, at its best score.
        var best: [String: (plan: CommandPlan, score: Double)] = [:]
        for candidate in candidates where (best[candidate.key]?.score ?? -1) < candidate.score {
            best[candidate.key] = (candidate.plan, candidate.score)
        }
        let ranked = best.values.sorted { $0.score > $1.score }
        if let outcome = pick(ranked.map { ($0.plan, $0.score) }, prompt: "Which one did you mean?") { return outcome }

        if verb == .open || verb == .find, query.count >= 3 {
            // Maybe a file: "open thesis draft".
            return .plan(CommandPlan(kind: .findFiles(query), summary: "Find files matching “\(query)”",
                                     details: ["No Space, workflow or app is called that, so this searches your Orbit folders."],
                                     hasSideEffects: false, subject: query))
        }
        if verb == nil {
            return .unknown("I don't know how to “\(rest)”. Try “open my coding room”, “run morning setup” or “find my notes”.")
        }
        let kind = verb == .activate ? "Space" : verb == .run ? "workflow" : "Space, workflow or app"
        return .unknown("No \(kind) matches “\(query)”.")
    }

    /// The query as typed, plus versions with a profile name taken out.
    func profileVariants(_ query: String, _ space: CommandVocabulary.SpaceEntry) -> [(String, (id: UUID, name: String, isDefault: Bool)?)] {
        var variants: [(String, (id: UUID, name: String, isDefault: Bool)?)] = [(query, nil)]
        for profile in space.profiles {
            let profileWords = NameMatcher.keywords(profile.name)
            let queryWords = NameMatcher.keywords(query)
            guard !profileWords.isEmpty, queryWords.count > profileWords.count else { continue }
            let tail = Array(queryWords.suffix(profileWords.count))
            if zip(tail, profileWords).allSatisfy({ NameMatcher.wordScore($0, $1) >= 0.8 }) {
                variants.append((queryWords.dropLast(profileWords.count).joined(separator: " "), profile))
            }
        }
        return variants
    }

    public func spacePlan(_ space: CommandVocabulary.SpaceEntry, profile: (id: UUID, name: String, isDefault: Bool)?) -> CommandPlan {
        let chosen = profile ?? space.defaultProfile
        var parameters: ActionParameters = ["space": .string(space.name)]
        if let profile { parameters["profile"] = .string(profile.name) }
        let summary = chosen.map { "Activate \(space.name) — \($0.name)" } ?? "Activate \(space.name)"
        return CommandPlan(kind: .actions([.init(SpaceActivateAction.id, parameters)]), summary: summary,
                           details: ["Runs the Space's activation: opens its apps and arranges its windows."],
                           hasSideEffects: true, subject: space.name)
    }

    public func workflowPlan(id: UUID, name: String) -> CommandPlan {
        CommandPlan(kind: .workflow(id, name: name), summary: "Run \(name)", hasSideEffects: true, subject: name)
    }

    public func launchAppPlan(_ app: CommandVocabulary.Named) -> CommandPlan {
        CommandPlan(kind: .actions([.init(LaunchApplicationAction.id, ["bundleId": .string(app.id)])]),
                    summary: "Open \(app.name)", hasSideEffects: true, subject: app.name)
    }

    // MARK: - Choosing

    /// The best plan, or choices when the top few are too close to call.
    func pick(_ ranked: [(plan: CommandPlan, score: Double)], prompt: String) -> ParseOutcome? {
        guard let top = ranked.first else { return nil }
        let close = ranked.prefix(4).filter { top.score - $0.score < NameMatcher.ambiguityMargin }
        if close.count > 1 {
            return .choices(prompt: prompt, close.map(\.plan))
        }
        return .plan(top.plan)
    }
}
