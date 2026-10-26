import AtlasCore
import AtlasSpaces
import SwiftUI

/// The group editor for a condition node: checks combined with AND (all)
/// or OR (any), each of which can be negated (NOT).
struct ConditionInspector: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep

    private var group: ConditionGroup { model.node(node.id)?.config.condition ?? ConditionGroup() }

    var body: some View {
        Section {
            Picker("Continue on “True” when", selection: Binding(
                get: { group.match },
                set: { match in update { $0.match = match } }
            )) {
                ForEach(ConditionGroup.Match.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ForEach(group.items) { item in
                ConditionItemEditor(model: model, item: item,
                                    update: { changed in update { g in if let i = g.items.firstIndex(where: { $0.id == item.id }) { g.items[i] = changed } } },
                                    remove: { update { $0.items.removeAll { $0.id == item.id } } })
            }
            Menu {
                ForEach(Array(ConditionCheck.templates.enumerated()), id: \.offset) { _, check in
                    Button(check.title) { update { $0.items.append(ConditionItem(check)) } }
                }
            } label: {
                Label("Add Check", systemImage: "plus")
            }
            .fixedSize()
        } header: {
            Text("Condition")
        } footer: {
            Text("Text fields accept {{trigger.path}}, {{var.name}} and other placeholders.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func update(_ change: (inout ConditionGroup) -> Void) {
        var copy = group
        change(&copy)
        model.updateNode(node.id, "Edit Condition") { $0.config.condition = copy }
    }
}

private struct ConditionItemEditor: View {
    @ObservedObject var model: FlowEditorModel
    let item: ConditionItem
    let update: (ConditionItem) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("NOT", isOn: Binding(get: { item.negated }, set: { negated in var c = item; c.negated = negated; update(c) }))
                    .toggleStyle(.button)
                    .help("Invert this check")
                Text(item.check.title).font(.callout.weight(.medium))
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            fields
            if let problem = item.check.validationError {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func set(_ check: ConditionCheck) {
        var copy = item
        copy.check = check
        update(copy)
    }

    private func text(_ value: String, _ make: @escaping (String) -> ConditionCheck) -> Binding<String> {
        Binding(get: { value }, set: { set(make($0)) })
    }

    private func op(_ value: ComparisonOperator, numeric: Bool = true, _ make: @escaping (ComparisonOperator) -> ConditionCheck) -> some View {
        Picker("", selection: Binding(get: { value }, set: { set(make($0)) })) {
            ForEach(numeric ? [.equals, .notEquals, .lessThan, .greaterThan] : ComparisonOperator.allCases, id: \.self) {
                Text($0.title).tag($0)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var fields: some View {
        switch item.check {
        case .appRunning(let id):
            TextField("Bundle identifier", text: text(id) { .appRunning(bundleID: $0) }).font(.body.monospaced())
        case .appFrontmost(let id):
            TextField("Bundle identifier", text: text(id) { .appFrontmost(bundleID: $0) }).font(.body.monospaced())
        case .activeSpace(_, let name):
            TextField("Space name", text: text(name) { .activeSpace(spaceID: Self.spaceID(named: $0, model: model), name: $0) })
            Text("Matched by the Space's identity, so renaming it later keeps working.").font(.caption2).foregroundStyle(.secondary)
        case .displayCount(let o, let count):
            HStack {
                op(o) { .displayCount(op: $0, count: count) }
                Stepper("\(count)", value: Binding(get: { count }, set: { set(.displayCount(op: o, count: $0)) }), in: 0...8)
            }
        case .fileExists(let path):
            TextField("Path", text: text(path) { .fileExists(path: $0) })
        case .fileExtension(let path, let ext):
            TextField("Path", text: text(path) { .fileExtension(path: $0, extensions: ext) })
            TextField("Extensions, e.g. pdf, png", text: text(ext) { .fileExtension(path: path, extensions: $0) })
        case .fileSize(let path, let o, let mb):
            TextField("Path", text: text(path) { .fileSize(path: $0, op: o, megabytes: mb) })
            HStack {
                op(o) { .fileSize(path: path, op: $0, megabytes: mb) }
                TextField("MB", value: Binding(get: { mb }, set: { set(.fileSize(path: path, op: o, megabytes: $0)) }), format: .number)
                    .frame(width: 80)
                Text("MB")
            }
        case .fileNameContains(let path, let t):
            TextField("Path", text: text(path) { .fileNameContains(path: $0, text: t) })
            TextField("Text", text: text(t) { .fileNameContains(path: path, text: $0) })
        case .fileNameMatches(let path, let pattern):
            TextField("Path", text: text(path) { .fileNameMatches(path: $0, pattern: pattern) })
            TextField("Regular expression", text: text(pattern) { .fileNameMatches(path: path, pattern: $0) }).font(.body.monospaced())
        case .fileAge(let path, let field, let o, let days):
            TextField("Path", text: text(path) { .fileAge(path: $0, field: field, op: o, days: days) })
            HStack {
                Picker("", selection: Binding(get: { field }, set: { set(.fileAge(path: path, field: $0, op: o, days: days)) })) {
                    Text("Days since created").tag(RuleCondition.DateField.created)
                    Text("Days since modified").tag(RuleCondition.DateField.modified)
                }
                .labelsHidden()
                .fixedSize()
                op(o) { .fileAge(path: path, field: field, op: $0, days: days) }
                TextField("Days", value: Binding(get: { days }, set: { set(.fileAge(path: path, field: field, op: o, days: $0)) }),
                          format: .number)
                    .frame(width: 60)
            }
        case .fileType(let path, let identifier):
            TextField("Path", text: text(path) { .fileType(path: $0, typeIdentifier: identifier) })
            TextField("Type, e.g. public.image", text: text(identifier) { .fileType(path: path, typeIdentifier: $0) }).font(.body.monospaced())
        case .fileSource(let path, let t):
            TextField("Path", text: text(path) { .fileSource(path: $0, text: t) })
            TextField("Site or app, e.g. github.com", text: text(t) { .fileSource(path: path, text: $0) })
        case .timeInRange(let a, let b):
            HStack {
                TextField("From", text: text(a) { .timeInRange(start: $0, end: b) }).frame(width: 70)
                Text("to")
                TextField("To", text: text(b) { .timeInRange(start: a, end: $0) }).frame(width: 70)
            }
        case .dayOfWeek(let days):
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                        get: { days.contains(day) },
                        set: { on in set(.dayOfWeek(days: on ? (days + [day]).sorted() : days.filter { $0 != day })) }
                    ))
                    .toggleStyle(.button)
                }
            }
        case .batteryLevel(let o, let percent):
            HStack {
                op(o) { .batteryLevel(op: $0, percent: percent) }
                Stepper("\(percent)%", value: Binding(get: { percent }, set: { set(.batteryLevel(op: o, percent: $0)) }), in: 1...100)
            }
        case .powerSource(let onAdapter):
            Picker("", selection: Binding(get: { onAdapter }, set: { set(.powerSource(onAdapter: $0)) })) {
                Text("On power adapter").tag(true)
                Text("On battery").tag(false)
            }
            .labelsHidden()
        case .compare(let l, let o, let r):
            TextField("Value, e.g. {{var.count}}", text: text(l) { .compare(left: $0, op: o, right: r) })
            HStack {
                op(o, numeric: false) { .compare(left: l, op: $0, right: r) }
                if o.needsRightSide {
                    TextField("Compared with", text: text(r) { .compare(left: l, op: o, right: $0) })
                }
            }
        }
    }

    static func spaceID(named name: String, model: FlowEditorModel) -> UUID {
        let spaces = (try? model.core.store.spaces()) ?? []
        return spaces.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id ?? UUID()
    }
}
