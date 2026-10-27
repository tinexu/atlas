import AtlasCore
import SwiftUI

/// "Describe an automation": AI (if you turned it on in the Companion) or
/// ATLAS's built-in understanding turns a sentence into a draft workflow.
/// You review the summary, assumptions and steps first; the draft is saved
/// turned off, and you edit it in the editor before turning it on.
public struct GenerateWorkflowSheet: View {
    let core: AtlasCore
    let apps: [(id: String, name: String)]
    let provider: (any IntentModelProvider)?
    let onCreated: (Workflow) -> Void
    @State private var prompt: String
    @State private var proposal: WorkflowProposal?
    @State private var error: String?
    @State private var working = false
    @State private var granted: Set<Permission> = []
    @Environment(\.dismiss) private var dismiss

    public init(core: AtlasCore, apps: [(id: String, name: String)], provider: (any IntentModelProvider)?, prompt: String = "",
                onCreated: @escaping (Workflow) -> Void) {
        self.core = core
        self.apps = apps
        self.provider = provider
        self.onCreated = onCreated
        _prompt = State(initialValue: prompt)
    }

    private var context: GenerationContext { core.generationContext(apps: apps, granted: granted) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe an Automation").font(.title2.weight(.semibold))
            Text(provider == nil
                 ? "ATLAS understands sentences like the examples below. Turn on AI in Companion settings for anything more complex."
                 : "Planned by AI, checked by ATLAS. Nothing is saved until you open it as a draft, and drafts start turned off.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("When I open Blender, activate Creative Studio and hide distracting apps", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                Button("Generate", action: generate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            if working { ProgressView("Working it out…").controlSize(.small) }
            if let error { Label(error, systemImage: "questionmark.bubble").foregroundStyle(.orange).font(.callout) }

            if let proposal {
                proposalView(proposal)
            } else {
                examples
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let proposal {
                    Button("Start Over") { self.proposal = nil }
                    Button("Open as Draft") { create(proposal) }
                        .buttonStyle(.borderedProminent)
                        .help("Saves it turned off and opens it in the editor")
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task { granted = Set(await core.permissions.allStatuses().filter { $0.value == .granted || $0.value == .managedBySystem }.keys) }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try").font(.headline)
            ForEach(["When I open Blender, activate Creative Studio and hide distracting apps",
                     "Every weekday at 9am open Safari and run Morning Setup",
                     "When a PDF arrives in Downloads, move it to Papers",
                     "When a focus session ends, notify me to stretch"], id: \.self) { example in
                Button(example) { prompt = example }.buttonStyle(.link)
            }
            Divider().padding(.vertical, 4)
            Text("Or start from a template").font(.headline)
            ForEach(WorkflowGenerator.templates(context: context), id: \.title) { template in
                Button {
                    do {
                        proposal = try WorkflowGenerator(core: core).proposal(from: template.blueprint, prompt: template.title, source: .template, context: context)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                } label: { Label(template.title, systemImage: "doc.on.doc") }
                .buttonStyle(.link)
            }
        }
    }

    private func proposalView(_ proposal: WorkflowProposal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(proposal.workflow.name).font(.headline)
                    Spacer()
                    Text(proposal.source.title).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let note = proposal.note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                Text(proposal.summary)
                if !proposal.assumptions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(proposal.assumptions, id: \.self) { assumption in
                            Label(assumption, systemImage: "lightbulb").font(.callout)
                        }
                        Text("Change any of these in the editor after opening the draft.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                GroupBox("Steps") {
                    Text(WorkflowExplainer.explain(proposal.workflow, registry: core.registry))
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(proposal.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(issue.severity == .error ? .red : .orange).font(.callout)
                }
            }
        }
    }

    private func generate() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        working = true
        error = nil
        let generator = WorkflowGenerator(core: core)
        let context = self.context
        Task {
            do {
                proposal = try await generator.generate(text, context: context, provider: provider)
            } catch {
                self.error = error.localizedDescription
                proposal = nil
            }
            working = false
        }
    }

    private func create(_ proposal: WorkflowProposal) {
        do {
            let saved = try core.saveDraft(proposal)
            onCreated(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shown above a generated workflow until you keep or discard it.
public struct DraftBanner: View {
    let core: AtlasCore
    let workflow: Workflow
    let onDiscard: () -> Void
    @State private var draft: GeneratedDraft?

    public init(core: AtlasCore, workflow: Workflow, onDiscard: @escaping () -> Void) {
        self.core = core
        self.workflow = workflow
        self.onDiscard = onDiscard
    }

    public var body: some View {
        Group {
            if let draft, draft.state == .draft {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Generated draft (\(draft.source.title)) · from “\(draft.prompt)”", systemImage: "wand.and.stars").font(.callout.weight(.semibold))
                        Spacer()
                        Button("Keep") { resolve(.kept) }
                        Button("Discard", role: .destructive) {
                            resolve(.discarded)
                            try? core.delete(workflowID: workflow.id)
                            onDiscard()
                        }
                    }
                    ForEach(draft.assumptions, id: \.self) { Label($0, systemImage: "lightbulb").font(.caption) }
                    Text(workflow.isEnabled ? "It's on." : "It's off until you turn it on with the switch in the header.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12))
            }
        }
        .onAppear { draft = try? core.store.draft(workflowID: workflow.id) }
    }

    private func resolve(_ state: GeneratedDraft.State) {
        guard var draft else { return }
        draft.state = state
        try? core.store.saveDraft(draft)
        self.draft = draft
    }
}
