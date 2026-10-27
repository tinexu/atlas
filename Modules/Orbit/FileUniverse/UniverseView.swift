import AppKit
import AtlasCore
import AtlasOrbit
import RealityKit
import SwiftUI

/// The 3D File Universe: each Orbit folder is a planet around your Mac,
/// with its biggest subfolders as moons. Double-click to fly into a
/// folder; files appear as small shapes, coloured and shaped by kind, with
/// small files gathered into "N files" clusters. Everything here can also
/// be done in the Browser tab.
struct UniverseView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var scene = UniverseScene()
    @State private var isVisible = true
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var scrollMonitor: Any?
    @State private var isHovering = false
    @State private var lastTap: (id: String, at: Date)?
    @State private var expandedCategory: FileCategory?
    @State private var closeUp = false
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Objects shown at once; more when zoomed in.
    private var detailLimit: Int { closeUp ? 300 : 120 }

    var body: some View {
        // A plain HStack, not HSplitView: inside a split view the RealityView's
        // drawing surface collapses and the Universe shows up empty.
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: NSColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1))
                if isVisible {
                    realityView
                } else {
                    Label("3D paused while ATLAS is in the background (saves battery)", systemImage: "pause.circle")
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                overlay
            }
            .background(VisibilityReader(isVisible: $isVisible))
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("3D view of your files. The Browser tab shows the same files as a list.")

            Divider()

            Group {
                if let entry = model.entry(model.selection) {
                    FileInspector(model: model, entry: entry).id(entry.path)
                } else {
                    UniverseLegend(model: model)
                }
            }
            .frame(width: 280)
        }
        .onChange(of: model.currentFolder) { _, _ in expandedCategory = nil }
    }

    private var realityView: some View {
        let content = universeContent()
        let health = model.health.map(HealthIndicators.init)
        return RealityView { realityContent in
            realityContent.camera = .virtual
            scene.root.removeFromParent()
            realityContent.add(scene.root)
        } update: { _ in
            scene.sync(content, health: health, reduceMotion: reduceMotion)
        }
        .gesture(
            SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                guard let id = scene.identifier(for: value.entity) else { return }
                handleTap(id)
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    scene.orbit(dx: Float(value.translation.width - lastDrag.width), dy: Float(value.translation.height - lastDrag.height))
                    lastDrag = value.translation
                }
                .onEnded { _ in lastDrag = .zero }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    scene.zoom(by: Float(value.magnification / lastMagnification))
                    lastMagnification = value.magnification
                    updateCloseUp()
                }
                .onEnded { _ in lastMagnification = 1 }
        )
        .onHover { isHovering = $0 }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
    }

    // MARK: Content

    private func universeContent() -> UniverseContent {
        _ = model.revision
        if let folder = model.currentFolder, let entry = model.entry(folder) {
            let children = model.children(of: folder, limit: 5_000)
            let folders = children.filter(\.isFolder)
            var files = children.filter { !$0.isFolder }
            var clusters: [UniverseContent.Cluster] = []
            if let expanded = expandedCategory {
                files = files.filter { $0.category == expanded }
            }
            let budget = max(0, detailLimit - folders.count)
            if files.count > budget {
                let shown = Array(files.prefix(budget))
                let rest = files.dropFirst(budget)
                clusters = Dictionary(grouping: rest, by: \.category)
                    .map { UniverseContent.Cluster(category: $0.key, count: $0.value.count, size: $0.value.reduce(0) { $0 + $1.size }) }
                    .sorted { $0.count > $1.count }
                files = shown
            }
            let items = (Array(folders.prefix(detailLimit)) + files).map { child in
                UniverseContent.Item(path: child.path, name: child.name, category: child.category, size: child.size, isFolder: child.isFolder,
                                     dimmed: model.highlight != .none && !model.highlight.matches(child))
            }
            let signature = "f|\(folder)|\(model.revision)|\(items.count)|\(clusters.count)|\(model.selection ?? "")|\(model.highlight)|\(model.filters.categories.count)|\(model.filters.size)|\(model.filters.date)|\(expandedCategory?.rawValue ?? "")|\(detailLimit)"
            return UniverseContent(mode: .folder(path: folder, name: entry.name, size: entry.size, items: items, clusters: clusters),
                                   selection: model.selection, signature: signature)
        }
        var planets = model.locations.map { location in
            let moons = model.children(of: location.path, limit: 200, applyFilters: false).filter(\.isFolder).prefix(8)
                .map { UniverseContent.Moon(path: $0.path, name: $0.name, size: $0.size) }
            return UniverseContent.Planet(id: "planet:" + location.path, name: location.name, size: location.totalSize,
                                          detail: "\(location.fileCount.formatted()) files · \(OrbitFormat.bytes(location.totalSize))",
                                          isProject: false, moons: Array(moons))
        }
        planets += model.projects.map { project in
            UniverseContent.Planet(id: "project:" + project.id.uuidString, name: project.name, size: Int64(project.links.count) * 50_000_000,
                                   detail: "\(project.links.count) item\(project.links.count == 1 ? "" : "s")", isProject: true, moons: [])
        }
        let signature = "o|\(model.revision)|\(planets.map { "\($0.id)\($0.size)\($0.moons.count)" }.joined())|\(model.selection ?? "")"
        return UniverseContent(mode: .overview(planets: planets), selection: model.selection, signature: signature)
    }

    // MARK: Interaction

    private func handleTap(_ id: String) {
        let isDouble = lastTap.map { $0.id == id && Date().timeIntervalSince($0.at) < 0.4 } ?? false
        lastTap = (id, Date())
        if id == "mac" {
            NotificationCenter.default.post(name: .orbitOpenHealth, object: nil)
            return
        }
        if id.hasPrefix("cluster:") {
            expandedCategory = FileCategory(rawValue: String(id.dropFirst("cluster:".count)))
            return
        }
        if id.hasPrefix("project:") {
            model.selectedProjectID = UUID(uuidString: String(id.dropFirst("project:".count)))
            if isDouble { model.tab = .projects }
            return
        }
        let path = String(id.drop { $0 != ":" }.dropFirst())
        if isDouble {
            if let entry = model.entry(path), !entry.isFolder {
                model.open(path)
            } else {
                model.enter(path)
            }
        } else {
            model.selection = path
        }
    }

    private func updateCloseUp() {
        let near = scene.cameraDistance < 10
        if near != closeUp { closeUp = near }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            scene.zoom(by: exp(Float(event.scrollingDeltaY) * 0.01))
            updateCloseUp()
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: Overlay

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Breadcrumb(model: model)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                TextField("Find and fly to…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(flyToSearch)
            }
            FilterBar(model: model)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .fixedSize(horizontal: false, vertical: true)
            if let expanded = expandedCategory {
                Button { expandedCategory = nil } label: {
                    Label("Showing all \(expanded.title.lowercased()) · show everything", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            HStack {
                Button {
                    scene.resetView()
                    model.selection = nil
                } label: { Label("Reset View", systemImage: "scope") }
                Text("Drag to orbit · scroll to zoom · click to select · double-click to go in")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let summary = model.indexingSummary {
                    ProgressView().controlSize(.small)
                    Text(summary).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(10)
    }

    private func flyToSearch() {
        let query = SearchQuery.parse(searchText)
        guard !query.isEmpty, let first = try? model.module.search.search(query, limit: 1).first else { return }
        model.reveal(inUniverse: first.entry.path)
    }
}

extension Notification.Name {
    /// Clicking the Mac planet asks the app to show Mac Health.
    public static let orbitOpenHealth = Notification.Name("atlas.orbit.openHealth")
}

/// Legend: what each colour and shape means, with counts for the current place.
struct UniverseLegend: View {
    @ObservedObject var model: OrbitViewModel

    var body: some View {
        let totals: [FileCategory: (count: Int, size: Int64)] = {
            _ = model.revision
            if let folder = model.currentFolder { return model.categoryTotals(under: folder) }
            var all: [FileCategory: (count: Int, size: Int64)] = [:]
            for location in model.locations {
                for (category, value) in model.categoryTotals(under: location.path) {
                    all[category] = ((all[category]?.count ?? 0) + value.count, (all[category]?.size ?? 0) + value.size)
                }
            }
            return all
        }()
        List {
            Section("Legend") {
                ForEach(FileCategory.allCases) { category in
                    HStack {
                        Circle().fill(OrbitFormat.color(category)).frame(width: 10, height: 10)
                        Label(category.title, systemImage: shapeSymbol(category))
                        Spacer()
                        if let total = totals[category] {
                            Text("\(total.count.formatted()) · \(OrbitFormat.bytes(total.size))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            Section {
                Text("Size grows with storage used, on a log scale. Planets are your Orbit folders; purple rings are projects. The Mac in the middle shows CPU, memory, disk and battery: click it for Mac Health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shapeSymbol(_ category: FileCategory) -> String {
        switch category {
        case .folder, .app, .other: return "circle.fill"
        case .document, .image: return "rectangle.fill"
        case .code, .archive: return "cube.fill"
        case .video, .audio: return "cylinder.fill"
        }
    }
}

/// Whether the window is on screen, so 3D rendering can stop when it isn't.
struct VisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onChange = { visible in if isVisible != visible { isVisible = visible } }
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
            report()
        }

        /// Low Power Mode and switching apps change whether 3D draws.
        private lazy var powerObserver: [NSObjectProtocol] = [
            NSNotification.Name.NSProcessInfoPowerStateDidChange, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            _ = powerObserver
            // A RealityKit view redraws every frame, so 3D only draws while
            // it's on screen, ATLAS is the app in front, and Low Power Mode is off.
            let visible = RenderPolicy.shouldDraw(windowVisible: window?.occlusionState.contains(.visible) ?? false,
                                                  appActive: NSApp.isActive, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            powerObserver.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
