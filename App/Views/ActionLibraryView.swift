import AtlasCore
import SwiftUI

/// Every registered action with what it needs and what it does. Users can
/// switch individual actions off here; disabled actions fail safely
/// wherever they're used (spec 7.6).
struct ActionLibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let descriptors = model.registry?.descriptors ?? []
        let categories = Array(Set(descriptors.map(\.category))).sorted()

        List {
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(descriptors.filter { $0.category == category }) { descriptor in
                        ActionRow(descriptor: descriptor)
                    }
                }
            }
        }
        .navigationTitle("Action Library")
    }
}

private struct ActionRow: View {
    @EnvironmentObject private var model: AppModel
    let descriptor: ActionDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: descriptor.symbolName)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(descriptor.title).font(.headline)
                    Text(descriptor.id.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(descriptor.summary).foregroundStyle(.secondary)

                if !descriptor.parameters.isEmpty {
                    Text("Takes: " + descriptor.parameters
                        .map { $0.isRequired && $0.defaultValue == nil ? $0.label : "\($0.label) (optional)" }
                        .joined(separator: ", "))
                        .font(.callout)
                }

                HStack(spacing: 6) {
                    if descriptor.confirmationRequired { Pill(text: "Asks before running", tint: .orange) }
                    Pill(text: descriptor.isIdempotent ? "Safe to retry" : "Never retried",
                        tint: descriptor.isIdempotent ? .green : .secondary)
                    ForEach(descriptor.permissions.sorted { $0.rawValue < $1.rawValue }) {
                        Pill(text: $0.title, tint: .blue)
                    }
                    ForEach(descriptor.sideEffects.sorted { $0.rawValue < $1.rawValue }, id: \.self) {
                        Pill(text: $0.title)
                    }
                }
            }

            Spacer()

            Toggle("Allowed", isOn: Binding(
                get: { model.isActionEnabled(descriptor.id) },
                set: { model.setAction(descriptor.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help("Turn off to stop every automation from using this action.")
        }
        .padding(.vertical, 6)
    }
}
