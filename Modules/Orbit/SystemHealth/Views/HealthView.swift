import AtlasCore
import AtlasOrbit
import Charts
import SwiftUI

/// Mac Health (spec 9): the Mac planet with CPU, memory, disk and battery,
/// always next to exact numbers; history charts; and the warnings that can
/// start Flow automations.
public struct HealthView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var range: HistoryRange = .hour
    @State private var history: [HealthSample] = []
    @State private var thresholds: [HealthThreshold] = []
    @State private var cycleCount: Int?
    @State private var createdAutomation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: OrbitViewModel) {
        self.model = model
    }

    enum HistoryRange: String, CaseIterable, Identifiable {
        case hour, day, week
        var id: Self { self }
        var title: String {
            switch self {
            case .hour: return "1 hour"
            case .day: return "24 hours"
            case .week: return "7 days"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .hour: return 3_600
            case .day: return 86_400
            case .week: return 7 * 86_400
            }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 24) {
                    MacPlanet(sample: model.health, animate: !reduceMotion)
                        .frame(width: 220, height: 220)
                        .accessibilityHidden(true)
                    readings
                }
                charts
                HStack(alignment: .top, spacing: 20) {
                    warnings.frame(maxWidth: .infinity, alignment: .leading)
                    processes.frame(width: 300, alignment: .leading)
                }
            }
            .padding(24)
        }
        .navigationTitle("Mac Health")
        .onAppear {
            model.module.health.setVisible(true)
            thresholds = model.module.health.thresholds
            cycleCount = model.module.health.batteryCycleCount()
            loadHistory()
        }
        .onDisappear { model.module.health.setVisible(false) }
        .onChange(of: range) { _, _ in loadHistory() }
        .onChange(of: model.health) { _, _ in
            if range == .hour { loadHistory() }
        }
    }

    private func loadHistory() {
        history = model.module.health.history(since: Date().addingTimeInterval(-range.seconds))
    }

    // MARK: Readings

    private var readings: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            if let s = model.health {
                reading("cpu", "CPU", "\(Int(s.cpu.rounded()))%", detail: "all cores", fraction: s.cpu / 100)
                reading("memorychip", "Memory", "\(OrbitFormat.bytes(s.memoryUsed)) of \(OrbitFormat.bytes(s.memoryTotal))",
                        detail: ["Pressure normal", "Pressure elevated", "Pressure critical"][min(max(s.memoryPressure, 0), 2)],
                        fraction: s.memoryPercent / 100)
                reading("internaldrive", "Disk", "\(OrbitFormat.bytes(s.diskFree)) free",
                        detail: "of \(OrbitFormat.bytes(s.diskTotal)) (\(Int(s.diskUsedPercent.rounded()))% used)", fraction: s.diskUsedPercent / 100)
                if let battery = s.battery {
                    reading(s.isCharging == true ? "battery.100.bolt" : "battery.75", "Battery", "\(Int(battery))%",
                            detail: [s.isCharging == true ? "Charging" : "On battery or full", cycleCount.map { "\($0) cycles" }]
                                .compactMap { $0 }.joined(separator: " · "),
                            fraction: battery / 100)
                } else {
                    GridRow {
                        Image(systemName: "powerplug")
                        Text("Battery")
                        Text("No battery").foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Taking the first reading…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func reading(_ symbol: String, _ title: String, _ value: String, detail: String, fraction: Double) -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).fontWeight(.medium)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.title3.monospacedDigit())
                ProgressView(value: min(max(fraction, 0), 1)).frame(width: 220)
                    .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Charts

    private var charts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if history.count < 2 {
                Text("History builds up while ATLAS runs: a reading every 5 seconds while this screen is open, every minute otherwise, kept for 7 days.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    chart("CPU %", \.cpu, domain: 0...100)
                    chart("Memory used %", \.memoryPercent, domain: 0...100)
                    chart("Free disk (GB)", { Double($0.diskFree) / 1e9 })
                    if history.contains(where: { $0.battery != nil }) {
                        chart("Battery %", { $0.battery ?? 0 }, domain: 0...100)
                    }
                }
            }
        }
    }

    private func chart(_ title: String, _ value: @escaping (HealthSample) -> Double, domain: ClosedRange<Double>? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            let base = Chart(history, id: \.takenAt) { sample in
                LineMark(x: .value("Time", sample.takenAt), y: .value(title, value(sample)))
                    .interpolationMethod(.monotone)
            }
            Group {
                if let domain { base.chartYScale(domain: domain) } else { base }
            }
            .frame(height: 120)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chart(_ title: String, _ keyPath: KeyPath<HealthSample, Double>, domain: ClosedRange<Double>? = nil) -> some View {
        chart(title, { $0[keyPath: keyPath] }, domain: domain)
    }

    // MARK: Warnings

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Warnings").font(.headline)
            Text("Each warning fires once when crossed and again only after things recover. A “Mac Health Warning” trigger in Flow can act on it.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($thresholds) { $threshold in
                HStack {
                    Toggle("", isOn: $threshold.isEnabled).labelsHidden()
                    Picker("", selection: $threshold.metric) {
                        ForEach(HealthThreshold.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("", value: $threshold.value, format: .number).frame(width: 60)
                    Text(threshold.metric.unit)
                    if threshold.metric == .cpu || threshold.metric == .memory {
                        Text("for")
                        TextField("", value: Binding(get: { threshold.sustainedSeconds / 60 }, set: { threshold.sustainedSeconds = max(0, $0) * 60 }),
                                  format: .number).frame(width: 44)
                        Text("min")
                    }
                    Spacer()
                    Button { thresholds.removeAll { $0.id == threshold.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Warning") { thresholds.append(HealthThreshold(metric: .diskFree, value: 20)) }
                Button("Restore Defaults") { thresholds = HealthThreshold.defaults }
                Spacer()
                Button(createdAutomation ? "Notification Automation Created" : "Notify Me with Flow") { createAutomation() }
                    .disabled(createdAutomation)
                    .help("Creates an automation: Mac Health Warning → Show Notification. Open it in Automations to change what happens.")
            }
            .controlSize(.small)
        }
        .onChange(of: thresholds) { _, value in model.module.health.thresholds = value }
    }

    private func createAutomation() {
        let trigger = WorkflowStep.trigger(TriggerCatalog.healthWarning, parameters: ["metric": "any"], at: NodePosition(x: 0, y: 0))
        let notify = WorkflowStep(actionID: ShowNotificationAction.id,
                                  parameters: ["title": "Mac Health", "body": "{{trigger.message}}"],
                                  position: NodePosition(x: 300, y: 0))
        let workflow = Workflow(
            name: "Mac Health warnings",
            summary: "Shows a notification when a Mac Health warning is crossed.",
            steps: [trigger, notify],
            connections: [WorkflowConnection(fromNode: trigger.id, fromPort: NodePort.controlOut, toNode: notify.id)],
            settings: WorkflowSettings(minimumInterval: 60)
        )
        do {
            _ = try model.module.core.save(workflow)
            createdAutomation = true
        } catch {
            model.onError(error.localizedDescription)
        }
    }

    // MARK: Processes

    private var processes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Busiest apps").font(.headline)
            let list = model.module.health.processes
            if list.isEmpty {
                Text("Shown while this screen is open. Only your own processes are visible to ATLAS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(list) { process in
                HStack {
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text("\(String(format: "%.0f", process.cpu))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    Text(OrbitFormat.bytes(process.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }
}

/// The Mac planet: a busier CPU spins the ring faster, a fuller disk crowds
/// it with more particles, memory pressure warms the colour. Still when
/// Reduce Motion is on.
struct MacPlanet: View {
    let sample: HealthSample?
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.26
                let cpu = (sample?.cpu ?? 0) / 100
                let disk = (sample?.diskUsedPercent ?? 0) / 100
                let pressure = sample?.memoryPressure ?? 0
                let time = animate ? timeline.date.timeIntervalSinceReferenceDate : 0
                let planetColor: Color = pressure >= 2 ? .red : pressure == 1 ? .orange : Color(red: 0.35, green: 0.55, blue: 0.95)

                // Ring particles: more when the disk is fuller.
                let count = max(4, Int(disk * 72))
                let speed = 0.15 + cpu * 2.5
                for i in 0..<count {
                    let angle = Double(i) / 72 * 2 * .pi + time * speed
                    let x = center.x + cos(angle) * radius * 1.75
                    let y = center.y + sin(angle) * radius * 0.55
                    let behind = sin(angle) < 0
                    let dot = CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(.teal.opacity(behind ? 0.35 : 0.9)))
                }
                let planet = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: planet), with: .radialGradient(
                    Gradient(colors: [planetColor.opacity(0.95), planetColor.opacity(0.55)]),
                    center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3), startRadius: 0, endRadius: radius * 1.4))
                // Battery as a thin arc around the planet.
                if let battery = sample?.battery {
                    var arc = Path()
                    arc.addArc(center: center, radius: radius + 8, startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * battery / 100), clockwise: false)
                    context.stroke(arc, with: .color(battery < 20 ? .red : .green), lineWidth: 3)
                }
                context.draw(Text("Mac").font(.headline).foregroundStyle(.white), at: center)
            }
        }
    }
}
