import AppKit
import Combine
import PowerPolicy

/// What one evaluation saw and did. Produced off the main thread.
struct PassOutcome {
    var battery: BatteryState?
    var modes: [PowerSource: PowerMode] = [:]
    var applied: [ModeChange] = []
    var problem: String?
    /// The root helper is missing or not authorized, so no mode can be changed.
    var needsHelper = false
}

@MainActor
final class PowerController: ObservableObject {
    private static let settingsKey = "settings"
    private static let enabledKey = "enabled"

    @Published var settings: PolicySettings {
        didSet {
            guard settings != oldValue else { return }
            if persistsChanges, let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
            scheduleEvaluation()
        }
    }
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            if persistsChanges { defaults.set(enabled, forKey: Self.enabledKey) }
            evaluate()
        }
    }
    @Published private(set) var battery: BatteryState?
    @Published private(set) var modes: [PowerSource: PowerMode] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var lastChange: String?
    @Published private(set) var needsHelper = false
    @Published private(set) var installingHelper = false

    /// False for a throwaway controller (the off-state snapshot) whose changes must not be saved.
    var persistsChanges = true
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "io.github.chrisfalck.power-modes.apply")
    private var running = false
    private var rerun = false
    private var rerunExact = false
    private var installFailure: String?
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
        if problem != nil || needsHelper { return "exclamationmark.triangle" }
        if !enabled { return "bolt.slash" }
        switch activeMode {
        case .high: return "bolt.fill"
        case .low: return "leaf.fill"
        case .automatic, .none: return "bolt"
        }
    }

    func resetToDefaults() { settings = .defaults }

    func installHelper() {
        guard !installingHelper else { return }
        installingHelper = true
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = SystemPower.installHelper()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.installingHelper = false
                    if let failure { ActivityLog.write("ERROR: \(failure)") } else { ActivityLog.write("Helper installed") }
                    self.installFailure = failure
                    // Exact: the first switch after installing should match what the sliders show.
                    self.evaluate(exact: true)
                }
            }
        }
    }

    /// Sliders fire continuously while dragged; wait until they settle before switching modes.
    private func scheduleEvaluation() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate(exact: true) }
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

    /// `exact` skips hysteresis: moved thresholds take effect as shown, not relative to the old mode.
    func evaluate(exact: Bool = false) {
        if running { rerun = true; rerunExact = rerunExact || exact; return }
        running = true
        let settings = settings, enabled = enabled
        queue.async {
            let outcome = Self.pass(settings: settings, enabled: enabled, exact: exact)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(outcome) }
            }
        }
    }

    func show(_ outcome: PassOutcome) {
        battery = outcome.battery
        modes = outcome.modes
        needsHelper = outcome.needsHelper
        if !needsHelper { installFailure = nil }
        problem = outcome.problem ?? installFailure
    }

    private func finish(_ outcome: PassOutcome) {
        if let message = outcome.problem, message != problem { ActivityLog.write("ERROR: \(message)") }
        if outcome.needsHelper, !needsHelper { ActivityLog.write("Helper not installed or not authorized; modes cannot be changed") }
        show(outcome)
        if let last = outcome.applied.last, let battery = outcome.battery {
            let time = Date().formatted(date: .omitted, time: .shortened)
            lastChange = "\(last.source.profileName) → \(last.mode.label) at \(battery.percent)% (\(time))"
        }
        running = false
        if rerun {
            let exact = rerunExact
            rerun = false
            rerunExact = false
            evaluate(exact: exact)
        }
    }

    nonisolated static func pass(settings: PolicySettings, enabled: Bool, exact: Bool = false, dryRun: Bool = false) -> PassOutcome {
        var outcome = PassOutcome(battery: SystemPower.batteryState(), modes: SystemPower.currentModes())
        outcome.needsHelper = !SystemPower.helperReady()
        guard enabled, let battery = outcome.battery else { return outcome }
        let plan = Policy.plan(percent: battery.percent, active: battery.source, settings: settings, current: outcome.modes,
                               margin: exact ? 0 : Policy.hysteresisMargin)
        guard !plan.isEmpty else { return outcome }
        if dryRun { outcome.applied = plan; return outcome }
        guard !outcome.needsHelper else { return outcome }
        for change in plan {
            let result = SystemPower.apply(change, active: battery.source)
            outcome.modes = SystemPower.currentModes()
            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard outcome.modes[change.source] == change.mode else {
                outcome.problem = "Could not set \(change.source.profileName) to \(change.mode.label)"
                    + (detail.isEmpty ? "." : ": \(detail)")
                continue
            }
            outcome.applied.append(change)
            ActivityLog.write("\(change.source.profileName) battery=\(battery.percent)% mode=\(change.mode.label)"
                + (result.status == 0 || detail.isEmpty ? "" : " (warning: \(detail))"))
        }
        return outcome
    }
}
