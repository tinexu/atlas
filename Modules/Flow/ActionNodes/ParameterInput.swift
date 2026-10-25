import AppKit
import AtlasCore
import SwiftUI
import UniformTypeIdentifiers

/// An input control chosen by parameter kind, generated from a
/// `ParameterSpec`. Text fields accept `{{templates}}`.
public struct ParameterInput: View {
    let spec: ParameterSpec
    @Binding var value: ActionValue?
    /// Shown instead of the field when the input is connected upstream.
    var connectedFrom: String?
    /// Names to offer as a menu (from `ParameterSpec.choicesFrom`).
    var choices: [String]?
    @State private var typingCustom = false

    public init(spec: ParameterSpec, value: Binding<ActionValue?>, connectedFrom: String? = nil, choices: [String]? = nil) {
        self.spec = spec
        self._value = value
        self.connectedFrom = connectedFrom
        self.choices = choices
    }

    private static let customTag = "\u{0}custom"

    private var placeholder: String {
        if let fallback = spec.defaultValue { return fallback.displayString }
        return spec.help ?? (spec.isRequired ? "Required" : "Optional")
    }

    private var text: Binding<String> {
        Binding(get: { value?.stringValue ?? "" }, set: { value = $0.isEmpty ? nil : .string($0) })
    }

    private var usesTemplate: Bool {
        value?.stringValue?.contains("{{") ?? false
    }

    public var body: some View {
        if let connectedFrom {
            Label("From \(connectedFrom)", systemImage: "link")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let choices, !choices.isEmpty {
            menu(choices)
        } else {
            field
        }
    }

    /// A menu of known names, with a way to type anything else (another
    /// name, or a {{placeholder}} for values that change per run).
    private func menu(_ choices: [String]) -> some View {
        let current = value?.stringValue ?? ""
        let match = choices.first { $0.caseInsensitiveCompare(current.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        let isCustom = typingCustom || (!current.isEmpty && match == nil)
        return VStack(alignment: .leading, spacing: 4) {
            Picker(spec.label, selection: Binding(
                get: { isCustom ? Self.customTag : (match ?? "") },
                set: { pick in
                    if pick == Self.customTag {
                        typingCustom = true
                    } else {
                        typingCustom = false
                        value = pick.isEmpty ? nil : .string(pick)
                    }
                }
            )) {
                Text(spec.isRequired ? "Choose…" : (spec.help ?? "None")).tag("")
                ForEach(choices, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("Type a name or {{placeholder}}…").tag(Self.customTag)
            }
            .labelsHidden()
            .fixedSize()
            if isCustom {
                TextField(spec.help ?? "Name or {{placeholder}}", text: text)
                if !current.isEmpty, !current.contains("{{") {
                    Text("Not one of your current \(spec.label.lowercased())s. It must match by the time this runs.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        switch spec.kind {
        case .boolean:
            Toggle(spec.label, isOn: Binding(
                get: { value?.boolValue ?? spec.defaultValue?.boolValue ?? false },
                set: { value = .bool($0) }
            ))
            .labelsHidden()

        case .number:
            if usesTemplate {
                TextField(placeholder, text: text)
            } else {
                TextField(placeholder, text: Binding(
                    get: { value?.displayString ?? "" },
                    set: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        value = trimmed.isEmpty ? nil : (Double(trimmed).map(ActionValue.number) ?? .string(trimmed))
                    }
                ))
                .frame(maxWidth: 140)
            }

        case .bundleIdentifier:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let id = value?.stringValue, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    }
                    TextField(placeholder, text: text)
                        .font(.body.monospaced())
                    Button("Choose App…") {
                        if let id = Self.chooseApplication() { value = .string(id) }
                    }
                }
                if let id = value?.stringValue, !id.isEmpty, !id.contains("{{"),
                   NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil {
                    Text("No installed app with this identifier").font(.caption2).foregroundStyle(.orange)
                }
            }

        case .filePath, .folderPath:
            HStack {
                TextField(placeholder, text: text)
                Button("Choose…") {
                    if let path = Self.choosePath(folders: spec.kind == .folderPath) { value = .string(path) }
                }
            }

        case .url, .text:
            if let options = spec.options {
                Picker(spec.label, selection: Binding(
                    get: { value?.stringValue ?? spec.defaultValue?.stringValue ?? options.first ?? "" },
                    set: { value = .string($0) }
                )) {
                    ForEach(options, id: \.self) { option in
                        Text(WindowPreset(rawValue: option)?.title ?? Self.title(forOption: option)).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                TextField(placeholder, text: text)
            }
        }
    }

    /// "runOnWake" → "Run on wake".
    static func title(forOption option: String) -> String {
        var words: [String] = []
        var current = ""
        for character in option {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        words.append(current)
        let sentence = words.joined(separator: " ").lowercased()
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    @MainActor
    public static func chooseApplication() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Paths under the home folder are stored with ~ so they stay portable.
    @MainActor
    public static func choosePath(folders: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.title = folders ? "Choose a Folder" : "Choose a File"
        panel.prompt = "Choose"
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
