import AppKit
import AtlasCore
import AtlasSpaces
import SwiftUI

/// Every rule in a layout as a table, plus a form for the selected one.
/// Anything the 3D or 2D canvas can do can be done here by typing.
struct RuleTable: View {
    @ObservedObject var model: WindowManagerModel

    var body: some View {
        let rules = model.draft?.rules ?? []
        VStack(spacing: 0) {
            Table(rules, selection: $model.selectedRuleID) {
                TableColumn("App") { rule in
                    HStack(spacing: 6) {
                        if let icon = AppIcons.icon(for: rule.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(rule.displayName)
                        if let match = rule.titleMatch {
                            Text("“\(match.pattern)”").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("Display") { rule in Text(rule.display.title) }
                TableColumn("Position") { rule in Text(Self.positionText(rule.frame)) }
                TableColumn("Size") { rule in Text(Self.sizeText(rule.frame)) }
                TableColumn("State") { rule in Text(rule.state.title) }
                TableColumn("Order") { rule in Text(rule.zOrder == 0 ? "Front" : "\(rule.zOrder + 1)") }
                    .width(50)
            }
            .frame(minHeight: 120)

            if let id = model.selectedRuleID, let rule = rules.first(where: { $0.id == id }) {
                Divider()
                RuleForm(model: model, rule: rule)
                    .id(rule.id)
            }
        }
    }

    static func positionText(_ frame: FractionalRect) -> String {
        if let preset = WindowPreset.matching(frame) { return preset.title }
        return "\(percent(frame.x)), \(percent(frame.y))"
    }

    static func sizeText(_ frame: FractionalRect) -> String {
        "\(percent(frame.width)) × \(percent(frame.height))"
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Edits one rule. Changes apply to the draft immediately; Save stores them.
private struct RuleForm: View {
    @ObservedObject var model: WindowManagerModel
    @State var rule: WindowRule

    private enum MatchKind: String, CaseIterable {
        case any = "Any window", contains = "Title contains", regex = "Title matches regex"
    }

    var body: some View {
        Form {
            HStack {
                LabeledContent("App") {
                    HStack {
                        TextField("Bundle identifier", text: $rule.bundleID)
                            .font(.body.monospaced())
                        Button("Choose App…") {
                            if let (id, name) = AppIcons.chooseApplication() {
                                rule.bundleID = id
                                rule.appName = name
                            }
                        }
                    }
                }
            }
            Picker("Window", selection: matchKind) {
                ForEach(MatchKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if rule.titleMatch != nil {
                TextField(matchKind.wrappedValue == .regex ? "Regular expression" : "Text in the title", text: matchPattern)
                if let problem = rule.titleMatch?.validationError {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            Picker("Display", selection: $rule.display) {
                Text(DisplayTarget.main.title).tag(DisplayTarget.main)
                Text(DisplayTarget.secondary.title).tag(DisplayTarget.secondary)
                Text(DisplayTarget.sameAsBefore.title).tag(DisplayTarget.sameAsBefore)
                Divider()
                ForEach(model.displays.filter { !$0.isMain }) { display in
                    Text(display.name).tag(DisplayTarget.display(id: display.id, name: display.name))
                }
                if case .display(let id, let name) = rule.display, !model.displays.contains(where: { $0.id == id }) {
                    Text("\(name) (not connected)").tag(rule.display)
                }
            }
            Picker("Position", selection: preset) {
                ForEach(WindowPreset.allCases) { Text($0.title).tag(Optional($0)) }
                Divider()
                Text("Custom").tag(WindowPreset?.none)
            }
            if preset.wrappedValue == nil {
                HStack {
                    percentField("Left", \.x)
                    percentField("Top", \.y)
                    percentField("Width", \.width)
                    percentField("Height", \.height)
                }
            }
            Picker("State", selection: $rule.state) {
                ForEach(WindowState.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Button { model.reorder(rule.id, toFront: true) } label: { Label("Bring Forward", systemImage: "square.2.layers.3d.top.filled") }
                Button { model.reorder(rule.id, toFront: false) } label: { Label("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") }
                Spacer()
                Button(role: .destructive) { model.removeRule(rule.id) } label: { Label("Remove", systemImage: "trash") }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260)
        .onChange(of: rule) { _, updated in model.updateRule(updated) }
        // Drags on the canvas and z-order buttons change the draft; keep the form in step.
        .onReceive(model.$draft) { draft in
            if let current = draft?.rules.first(where: { $0.id == rule.id }), current != rule {
                rule = current
            }
        }
    }

    private var matchKind: Binding<MatchKind> {
        Binding(
            get: {
                switch rule.titleMatch {
                case nil: return .any
                case .contains: return .contains
                case .regex: return .regex
                }
            },
            set: { kind in
                let pattern = rule.titleMatch?.pattern ?? ""
                switch kind {
                case .any: rule.titleMatch = nil
                case .contains: rule.titleMatch = .contains(pattern)
                case .regex: rule.titleMatch = .regex(pattern)
                }
            }
        )
    }

    private var matchPattern: Binding<String> {
        Binding(
            get: { rule.titleMatch?.pattern ?? "" },
            set: { text in
                if case .regex = rule.titleMatch { rule.titleMatch = .regex(text) } else { rule.titleMatch = .contains(text) }
            }
        )
    }

    private var preset: Binding<WindowPreset?> {
        Binding(
            get: { WindowPreset.matching(rule.frame) },
            set: { preset in
                if let preset {
                    rule.frame = preset.rect
                } else if WindowPreset.matching(rule.frame) != nil {
                    // Nudge off the preset so "Custom" sticks and shows its fields.
                    rule.frame = FractionalRect(x: rule.frame.x + 0.05, y: rule.frame.y + 0.05,
                                                width: rule.frame.width * 0.9, height: rule.frame.height * 0.9).clamped
                }
            }
        )
    }

    private func percentField(_ title: String, _ key: WritableKeyPath<FractionalRect, Double>) -> some View {
        TextField(title, value: Binding(
            get: { (rule.frame[keyPath: key] * 100).rounded() },
            set: { rule.frame[keyPath: key] = $0 / 100; rule.frame = rule.frame.clamped }
        ), format: .number)
        .frame(maxWidth: 70)
        .help("\(title), as a percentage of the display's usable area")
    }
}
