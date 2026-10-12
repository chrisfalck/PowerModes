import AppKit
import SwiftUI
import PowerPolicy

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--dry-run" {
            dryRun()
        } else if arguments.first == "--snapshot", arguments.count == 2 {
            MainActor.assumeIsolated { snapshot(to: arguments.last!) }
        } else if !arguments.isEmpty {
            FileHandle.standardError.write(Data("Usage: PowerModes [--dry-run | --snapshot <file.png>]\n".utf8))
            exit(2)
        } else {
            PowerModesApp.main()
        }
    }

    /// Prints what the saved settings would do right now, without changing anything.
    private static func dryRun() {
        let controller = MainActor.assumeIsolated { PowerController(monitor: false) }
        let (settings, enabled) = MainActor.assumeIsolated { (controller.settings, controller.enabled) }
        let outcome = PowerController.pass(settings: settings, enabled: enabled, dryRun: true)
        guard let battery = outcome.battery else { print("No battery found"); exit(1) }
        print("\(battery.source.profileName) battery=\(battery.percent)% automatic-switching=\(enabled ? "on" : "off") hysteresis=\(Policy.hysteresisMargin)%")
        for source in PowerSource.allCases {
            let thresholds = settings[source]
            let current = outcome.modes[source]?.label ?? "unknown"
            let high = thresholds.usesHighPower ? "\(thresholds.highMin)%" : "never"
            print("\(source.profileName): high>=\(high) auto>=\(thresholds.autoMin)% current=\(current) desired=\(thresholds.mode(at: battery.percent, holding: outcome.modes[source], margin: Policy.hysteresisMargin).label)")
        }
        print(outcome.applied.isEmpty ? "No change needed" : "Would change: "
            + outcome.applied.map { "\($0.source.profileName) → \($0.mode.label)" }.joined(separator: ", "))
    }

    /// Renders the popover to a PNG, for checking the layout without opening the menu.
    @MainActor
    private static func snapshot(to path: String) {
        _ = NSApplication.shared
        let controller = PowerController(monitor: false)
        let outcome = PowerController.pass(settings: controller.settings, enabled: false)
        controller.show(outcome)
        let host = NSHostingView(rootView: ContentView(controller: controller))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { exit(1) }
    }
}

struct PowerModesApp: App {
    @StateObject private var controller = PowerController()

    init() {
        // The launch agent and a manual launch would otherwise fight over the same profiles.
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0 != NSRunningApplication.current }
        if !identifier.isEmpty, !others.isEmpty { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: controller.menuSymbol)
                .accessibilityLabel("Power Modes")
        }
        .menuBarExtraStyle(.window)
    }
}
