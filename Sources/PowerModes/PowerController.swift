import AppKit
import Combine
import PowerPolicy

/// What one evaluation saw and did. Produced off the main thread.
struct PassOutcome {
    var battery: BatteryState?
    var modes: [PowerSource: PowerMode] = [:]
    var applied: [ModeChange] = []
    var problem: String?
}

@MainActor
final class PowerController: ObservableObject {
    private static let settingsKey = "settings"
    private static let enabledKey = "enabled"

    @Published var settings: PolicySettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
            scheduleEvaluation()
        }
    }
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            evaluate()
        }
    }
    @Published private(set) var battery: BatteryState?
    @Published private(set) var modes: [PowerSource: PowerMode] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var lastChange: String?

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "io.github.chrisfalck.power-modes.apply")
    private var running = false
    private var rerun = false
    private var debounce: DispatchWorkItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, monitor: Bool = true) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(PolicySettings.self, from: data) {
            settings = saved
        } else {
            settings = .defaults
        }
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        battery = SystemPower.batteryState()
        guard monitor else { return }
        startMonitoring()
    }

    var activeMode: PowerMode? { battery.flatMap { modes[$0.source] } }

    var menuSymbol: String {
        if problem != nil { return "exclamationmark.triangle" }
        if !enabled { return "bolt.slash" }
        switch activeMode {
        case .high: return "bolt.fill"
        case .low: return "leaf.fill"
        case .automatic, .none: return "bolt"
        }
    }

    func resetToDefaults() { settings = .defaults }

    /// Sliders fire continuously while dragged; wait until they settle before switching modes.
    private func scheduleEvaluation() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func startMonitoring() {
        SystemPower.startPowerSourceNotifications()
        let evaluateOnMain: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: SystemPower.powerSourceChanged, object: nil, queue: .main, using: evaluateOnMain))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: evaluateOnMain))
        // Catches mode changes made elsewhere (System Settings, pmset) that send no power-source event.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func evaluate() {
        if running { rerun = true; return }
        running = true
        let settings = settings, enabled = enabled
        queue.async {
            let outcome = Self.pass(settings: settings, enabled: enabled)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(outcome) }
            }
        }
    }

    func show(_ outcome: PassOutcome) {
        battery = outcome.battery
        modes = outcome.modes
        problem = outcome.problem
    }

    private func finish(_ outcome: PassOutcome) {
        if outcome.problem != problem, let message = outcome.problem { ActivityLog.write("ERROR: \(message)") }
        show(outcome)
        if let last = outcome.applied.last, let battery = outcome.battery {
            let time = Date().formatted(date: .omitted, time: .shortened)
            lastChange = "\(last.source.profileName) → \(last.mode.label) at \(battery.percent)% (\(time))"
        }
        running = false
        if rerun { rerun = false; evaluate() }
    }

    nonisolated static func pass(settings: PolicySettings, enabled: Bool, dryRun: Bool = false) -> PassOutcome {
        var outcome = PassOutcome(battery: SystemPower.batteryState(), modes: SystemPower.currentModes())
        guard enabled, let battery = outcome.battery else { return outcome }
        let plan = Policy.plan(percent: battery.percent, active: battery.source, settings: settings, current: outcome.modes)
        guard !plan.isEmpty else { return outcome }
        if dryRun { outcome.applied = plan; return outcome }
        guard FileManager.default.isExecutableFile(atPath: SystemPower.helperPath) else {
            outcome.problem = "Helper not installed, so modes cannot be changed. Run scripts/install-helper.sh with sudo."
            return outcome
        }
        for change in plan {
            let result = SystemPower.apply(change, active: battery.source)
            outcome.modes = SystemPower.currentModes()
            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard outcome.modes[change.source] == change.mode else {
                if detail.contains("password is required") || detail.contains("not allowed") {
                    outcome.problem = "Helper is not authorized. Run scripts/install-helper.sh with sudo."
                } else {
                    outcome.problem = "Could not set \(change.source.profileName) to \(change.mode.label)"
                        + (detail.isEmpty ? "." : ": \(detail)")
                }
                continue
            }
            outcome.applied.append(change)
            ActivityLog.write("\(change.source.profileName) battery=\(battery.percent)% mode=\(change.mode.label)"
                + (result.status == 0 || detail.isEmpty ? "" : " (warning: \(detail))"))
        }
        return outcome
    }
}
