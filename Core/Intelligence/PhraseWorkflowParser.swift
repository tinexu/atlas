import Foundation

/// Builds a workflow blueprint from a short English description without
/// AI: one trigger phrase ("when I open Blender", "every weekday at 9",
/// "when a PDF arrives in Downloads") and action clauses joined by "and"
/// or commas ("activate Creative Studio and hide distracting apps").
/// Anything it has to guess is written down as an assumption.
public enum PhraseWorkflowParser {
    static let distractingApps = ["com.apple.Music", "com.apple.MobileSMS", "com.spotify.client", "com.tinyspeck.slackmacgap",
                                  "com.hnc.Discord", "com.apple.TV", "com.apple.news"]
    static let actionVerbs: Set<String> = ["activate", "open", "launch", "start", "switch", "go", "hide", "quit", "close", "apply",
                                           "arrange", "run", "move", "notify", "remind", "show", "save", "tell", "set", "begin", "put"]

    public static func parse(_ raw: String, context: GenerationContext) -> WorkflowBlueprint? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        text = text.replacingOccurrences(of: "’", with: "'")
        guard !text.isEmpty else { return nil }
        var assumptions: [String] = []

        let (trigger, rest, triggerSummary) = parseTrigger(text, context: context, assumptions: &assumptions)
        var steps: [WorkflowBlueprint.Step] = []
        var summaries: [String] = []
        for clause in clauses(rest) {
            if let (step, summary) = parseAction(clause, trigger: trigger, context: context, assumptions: &assumptions) {
                steps.append(contentsOf: step)
                summaries.append(summary)
            } else {
                assumptions.append("I didn't understand “\(clause)”, so it isn't in the draft. Add that step yourself.")
            }
        }
        guard !steps.isEmpty else { return nil }
        let summary = (triggerSummary.map { "\($0), " } ?? "When you run it, ") + summaries.joined(separator: ", then ") + "."
        let name = summaries.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Generated Automation"
        return WorkflowBlueprint(name: triggerSummary.map { "\(name) (\($0.lowercased()))" }.map { String($0.prefix(60)) } ?? name,
                                 summary: summary.prefix(1).uppercased() + summary.dropFirst(),
                                 assumptions: assumptions, trigger: trigger, steps: steps)
    }

    // MARK: - Trigger

    static func parseTrigger(_ text: String, context: GenerationContext,
                             assumptions: inout [String]) -> (WorkflowBlueprint.Trigger?, String, String?) {
        let lower = text.lowercased()
        func after(_ prefix: String) -> String? {
            guard let range = lower.range(of: prefix, options: [.anchored]) else { return nil }
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let whenPrefixes = ["whenever i ", "when i ", "every time i ", "each time i ", "if i ", "once i "]
        for prefix in whenPrefixes {
            guard let tail = after(prefix) else { continue }
            let words = tail.split(separator: " ").map(String.init)
            guard let verb = words.first?.lowercased() else { break }
            // "when I open Blender, …" / "when I quit Xcode …"
            if ["open", "launch", "start", "quit", "close"].contains(verb) {
                let (subject, remainder) = splitSubject(Array(words.dropFirst()))
                guard let app = context.app(named: subject) else {
                    assumptions.append("No installed app matches “\(subject)”, so the trigger is set to any app. Choose the app in the trigger.")
                    let type = ["quit", "close"].contains(verb) ? TriggerCatalog.appQuit : TriggerCatalog.appLaunched
                    return (.init(type: type), remainder, "When any app \(type == TriggerCatalog.appQuit ? "quits" : "opens")")
                }
                let quits = ["quit", "close"].contains(verb)
                return (.init(type: quits ? TriggerCatalog.appQuit : TriggerCatalog.appLaunched, parameters: [.init("app", app.id)]),
                        remainder, "When \(app.name) \(quits ? "quits" : "opens")")
            }
            // "when I switch to Coding Lab, …"
            if verb == "switch" || verb == "activate" || verb == "enter" {
                let subjectWords = Array(words.dropFirst(verb == "switch" && words.count > 1 && words[1].lowercased() == "to" ? 2 : 1))
                let (subject, remainder) = splitSubject(subjectWords)
                if let space = context.space(named: subject) {
                    return (.init(type: TriggerCatalog.spaceActivated, parameters: [.init("space", space)]), remainder, "When \(space) is activated")
                }
            }
            // "when I connect a display / plug in / wake my Mac"
            if tail.lowercased().hasPrefix("connect a") || tail.lowercased().hasPrefix("plug in a") && tail.lowercased().contains("display") {
                return (.init(type: TriggerCatalog.displayChanged), remainderAfterComma(tail), "When displays change")
            }
            if tail.lowercased().hasPrefix("plug in") {
                return (.init(type: TriggerCatalog.powerConnected), remainderAfterComma(tail), "When the Mac is plugged in")
            }
            if tail.lowercased().hasPrefix("unplug") {
                return (.init(type: TriggerCatalog.powerDisconnected), remainderAfterComma(tail), "When the Mac is unplugged")
            }
            if tail.lowercased().hasPrefix("wake") {
                return (.init(type: TriggerCatalog.woke), remainderAfterComma(tail), "When the Mac wakes")
            }
            if tail.lowercased().hasPrefix("download") {
                let folder = (context.folders.first { $0.lowercased().hasSuffix("downloads") } ?? "~/Downloads")
                return (.init(type: TriggerCatalog.fileCreated, parameters: [.init("folder", folder)]), remainderAfterComma(tail),
                        "When a file arrives in Downloads")
            }
        }
        // "when my mac wakes", "when a focus session ends", "when a file arrives in downloads", "when my battery is low"
        if let tail = after("when ") ?? after("whenever ") {
            let t = tail.lowercased()
            if t.hasPrefix("my mac wakes") || t.hasPrefix("the mac wakes") {
                return (.init(type: TriggerCatalog.woke), remainderAfterComma(tail), "When the Mac wakes")
            }
            if t.contains("focus session ends") || t.hasPrefix("focus ends") {
                return (.init(type: TriggerCatalog.focusEnded), remainderAfterComma(tail), "When a focus session ends")
            }
            if t.contains("battery") {
                let percent = firstNumber(in: t) ?? 20
                return (.init(type: TriggerCatalog.batteryLow, parameters: [.init("percent", String(percent))]), remainderAfterComma(tail),
                        "When the battery drops below \(percent)%")
            }
            if t.contains("display") || t.contains("monitor") {
                return (.init(type: TriggerCatalog.displayChanged), remainderAfterComma(tail), "When displays change")
            }
            if let match = t.range(of: #"(a|an|any|new)? ?([a-z0-9]+ )?(file|pdf|image|screenshot|download)s? (arrives|is added|appears|lands|is downloaded|shows up)( in| to)? ([^,]+)"#,
                                   options: .regularExpression) {
                let phrase = String(t[match])
                let folderWord = phrase.components(separatedBy: CharacterSet(charactersIn: " ")).last ?? "downloads"
                let folder = context.folders.first { ($0 as NSString).lastPathComponent.lowercased() == folderWord }
                    ?? "~/" + folderWord.prefix(1).uppercased() + folderWord.dropFirst()
                var parameters: [WorkflowBlueprint.Parameter] = [.init("folder", folder)]
                if phrase.contains("pdf") { parameters.append(.init("extensions", "pdf")) }
                if phrase.contains("image") || phrase.contains("screenshot") { parameters.append(.init("extensions", "png, jpg, jpeg, heic")) }
                if !context.folders.contains(where: { ($0 as NSString).lastPathComponent.lowercased() == folderWord }) {
                    assumptions.append("I assumed the folder is \(folder). File actions only work in folders you've added to Orbit.")
                }
                return (.init(type: TriggerCatalog.fileCreated, parameters: parameters), remainderAfterComma(tail),
                        "When a \(phrase.contains("pdf") ? "PDF" : "file") arrives in \((folder as NSString).lastPathComponent)")
            }
            for space in context.spaces where t.hasPrefix(space.lowercased()) && (t.contains("activat") || t.contains("starts")) {
                return (.init(type: TriggerCatalog.spaceActivated, parameters: [.init("space", space)]), remainderAfterComma(tail),
                        "When \(space) is activated")
            }
        }
        // "N minutes before (each|a|any) meeting / event"
        if let match = lower.range(of: #"^(\d+) ?(minutes?|mins?) before (each |a |any |every |my )?(meeting|event|calendar event)s?"#, options: .regularExpression) {
            let minutes = firstNumber(in: String(lower[match])) ?? 10
            return (.init(type: TriggerCatalog.calendarEventApproaching, parameters: [.init("minutesBefore", String(minutes))]),
                    remainderAfterComma(String(text[match.upperBound...])), "\(minutes) minutes before calendar events")
        }
        // "every weekday at 9", "every day at 8:30am", "every monday and friday at 17:00", "each morning at 7"
        if let match = lower.range(of: #"^(every|each) ([a-z ,]+?) at ([0-9: ]+(am|pm)?)"#, options: .regularExpression) {
            let phrase = String(lower[match])
            let time = parseTime(phrase.components(separatedBy: " at ").last ?? "9") ?? "09:00"
            var parameters: [WorkflowBlueprint.Parameter] = [.init("time", time)]
            var label = "Every day at \(time)"
            if phrase.contains("weekday") {
                parameters += [.init("repeat", "weekly"), .init("days", "mon, tue, wed, thu, fri")]
                label = "Every weekday at \(time)"
            } else if phrase.contains("weekend") {
                parameters += [.init("repeat", "weekly"), .init("days", "sat, sun")]
                label = "Every weekend day at \(time)"
            } else {
                let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
                let days = names.filter { phrase.contains($0) }
                if !days.isEmpty {
                    parameters += [.init("repeat", "weekly"), .init("days", days.joined(separator: ", "))]
                    label = "Every \(days.joined(separator: ", ")) at \(time)"
                } else {
                    parameters.append(.init("repeat", "daily"))
                }
            }
            return (.init(type: TriggerCatalog.timeReached, parameters: parameters), remainderAfterComma(String(text[match.upperBound...])), label)
        }
        return (nil, text, nil)
    }

    /// Splits "Blender, activate Creative Studio" or "Blender activate …"
    /// into the subject and the rest.
    static func splitSubject(_ words: [String]) -> (String, String) {
        var subject: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.hasSuffix(",") {
                subject.append(String(word.dropLast()))
                index += 1
                break
            }
            if !subject.isEmpty, actionVerbs.contains(word.lowercased()) || word.lowercased() == "then" { break }
            subject.append(word)
            index += 1
        }
        var rest = words[index...].joined(separator: " ")
        if rest.lowercased().hasPrefix("then ") { rest = String(rest.dropFirst(5)) }
        return (subject.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters), rest)
    }

    static func remainderAfterComma(_ text: String) -> String {
        if let comma = text.firstIndex(of: ",") { return String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespaces) }
        // No comma: drop words up to the first action verb.
        let words = text.split(separator: " ").map(String.init)
        if let first = words.firstIndex(where: { actionVerbs.contains($0.lowercased()) }) { return words[first...].joined(separator: " ") }
        return ""
    }

    static func clauses(_ text: String) -> [String] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.lowercased().hasPrefix("then ") { t = String(t.dropFirst(5)) }
        return t.replacingOccurrences(of: ", and then ", with: "|").replacingOccurrences(of: ", then ", with: "|")
            .replacingOccurrences(of: " and then ", with: "|").replacingOccurrences(of: ", and ", with: "|")
            .replacingOccurrences(of: " and ", with: "|").replacingOccurrences(of: ", ", with: "|").replacingOccurrences(of: " then ", with: "|")
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Actions

    static func parseAction(_ clause: String, trigger: WorkflowBlueprint.Trigger?, context: GenerationContext,
                            assumptions: inout [String]) -> ([WorkflowBlueprint.Step], String)? {
        let lower = clause.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        guard let verb = words.first else { return nil }
        let object = words.dropFirst().joined(separator: " ")
        let objectText = clause.split(separator: " ").dropFirst().joined(separator: " ")
        let cleanedObject = object.replacingOccurrences(of: "^(my|the|to) ", with: "", options: .regularExpression)

        switch verb {
        case "activate", "open", "launch", "start", "switch", "go", "enter":
            let target = cleanedObject.replacingOccurrences(of: "^(to|into) ", with: "", options: .regularExpression)
            if lower.contains("focus"), let minutes = firstNumber(in: lower) ?? (lower.contains("focus") ? 25 : nil), verb == "start" {
                return ([.init(action: "timer.focus.start", parameters: [.init("minutes", String(minutes))])], "start a \(minutes)-minute focus session")
            }
            if verb != "launch", let space = context.space(named: target) {
                return ([.init(action: "space.activate", parameters: [.init("space", space)], label: "Activate \(space)")], "activate \(space)")
            }
            if let app = context.app(named: target) {
                return ([.init(action: "application.launch", parameters: [.init("bundleId", app.id)], label: "Open \(app.name)")], "open \(app.name)")
            }
            if verb == "activate" || verb == "switch" || verb == "go" {
                assumptions.append("No Space is called “\(target)”. Pick one in the step.")
            }
            return nil
        case "hide", "quit", "close", "minimize":
            let action = verb == "hide" ? "application.hide" : verb == "minimize" ? "application.minimize" : "application.quit"
            let verbText = verb == "close" ? "quit" : verb
            if object.contains("distract") || object.contains("other apps") {
                let installed = distractingApps.compactMap { id in context.apps.first { $0.id == id } }
                let chosen = installed.isEmpty ? [("com.apple.Music", "Music"), ("com.apple.MobileSMS", "Messages")] : installed.prefix(3).map { ($0.id, $0.name) }
                assumptions.append("I assumed “distracting apps” means \(chosen.map(\.1).joined(separator: " and ")). Change the steps if you meant others.")
                return (chosen.map { .init(action: action, parameters: [.init("bundleId", $0.0)], label: "\(verbText.capitalized) \($0.1)") },
                        "\(verbText) \(chosen.map(\.1).joined(separator: " and "))")
            }
            let names = cleanedObject.components(separatedBy: CharacterSet(charactersIn: "/&")).map { $0.trimmingCharacters(in: .whitespaces) }
            let apps = names.compactMap { context.app(named: $0) }
            guard !apps.isEmpty else { return nil }
            return (apps.map { .init(action: action, parameters: [.init("bundleId", $0.id)], label: "\(verbText.capitalized) \($0.name)") },
                    "\(verbText) \(apps.map(\.name).joined(separator: " and "))")
        case "apply", "arrange", "use":
            let name = cleanedObject.replacingOccurrences(of: " (window )?layout$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^(windows|my windows)( for| like)? ", with: "", options: .regularExpression)
            guard let layout = NameMatcher.rank(name, in: context.layouts, name: { $0 }).first?.item else {
                if !name.isEmpty { assumptions.append("No window layout is called “\(name)”. Capture one in the Window Manager, then pick it in the step.") }
                return nil
            }
            return ([.init(action: "window.applyLayout", parameters: [.init("layout", layout)])], "arrange windows with \(layout)")
        case "run":
            guard let match = NameMatcher.rank(cleanedObject, in: context.workflows, name: \.name).first else { return nil }
            return ([.init(action: WorkflowGenerator.runWorkflowAction, parameters: [.init("workflow", match.item.name)])], "run \(match.item.name)")
        case "move", "put":
            guard trigger?.type == TriggerCatalog.fileCreated, let range = lower.range(of: " to ") ?? lower.range(of: " into ") else { return nil }
            let destinationWord = String(clause[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^(my|the|a) ", with: "", options: [.regularExpression, .caseInsensitive])
            let base = trigger?.parameters.first { $0.key == "folder" }?.value ?? "~/Downloads"
            let destination = destinationWord.contains("/") ? destinationWord : (base as NSString).appendingPathComponent(destinationWord.replacingOccurrences(of: " folder", with: ""))
            return ([.init(action: "file.move", parameters: [.init("path", "{{trigger.path}}"), .init("destination", destination)])],
                    "move the file to \((destination as NSString).lastPathComponent)")
        case "notify", "remind", "tell", "show":
            var message = objectText.replacingOccurrences(of: "^(me|me that|me to|me about)\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            if message.isEmpty { message = "Done" }
            return ([.init(action: "notification.show", parameters: [.init("title", message.prefix(1).uppercased() + message.dropFirst())])],
                    "notify you")
        case "save":
            guard lower.contains("snapshot") || lower.contains("layout") || lower.contains("windows") else { return nil }
            return ([.init(action: "window.snapshot.save")], "save a snapshot of your windows")
        case "set", "begin":
            guard lower.contains("timer") || lower.contains("focus") else { return nil }
            let minutes = firstNumber(in: lower) ?? 25
            if lower.contains("focus") {
                return ([.init(action: "timer.focus.start", parameters: [.init("minutes", String(minutes))])], "start a \(minutes)-minute focus session")
            }
            return ([.init(action: "timer.start", parameters: [.init("name", "Timer"), .init("seconds", String(minutes * 60))])], "start a \(minutes)-minute timer")
        default:
            return nil
        }
    }

    // MARK: - Helpers

    static func firstNumber(in text: String) -> Int? {
        text.range(of: #"\d+"#, options: .regularExpression).flatMap { Int(text[$0]) }
    }

    /// "9", "9am", "9:30", "21:00", "7 pm" → "HH:mm".
    static func parseTime(_ text: String) -> String? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        let pm = t.hasSuffix("pm"), am = t.hasSuffix("am")
        let digits = t.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard var hour = parts.first, (0...23).contains(hour) else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        if pm, hour < 12 { hour += 12 }
        if am, hour == 12 { hour = 0 }
        return String(format: "%02d:%02d", hour, minute)
    }
}
