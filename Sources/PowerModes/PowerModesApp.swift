import AppKit
import Combine
import SwiftUI
import PowerPolicy

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--dry-run" {
            dryRun()
        } else if arguments.first == "--snapshot", arguments.count == 2 || (arguments.count == 3 && arguments.last == "off") {
            MainActor.assumeIsolated { snapshot(to: arguments.dropFirst().first!, switchedOff: arguments.count == 3) }
        } else if !arguments.isEmpty {
            FileHandle.standardError.write(Data("Usage: PowerModes [--dry-run | --snapshot <file.png> [off]]\n".utf8))
            exit(2)
        } else {
            // The launch agent and a manual launch would otherwise fight over the same profiles.
            let identifier = Bundle.main.bundleIdentifier ?? ""
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0 != NSRunningApplication.current }
            if !identifier.isEmpty, !others.isEmpty { exit(0) }
            MainActor.assumeIsolated {
                let delegate = AppDelegate()
                let app = NSApplication.shared
                app.delegate = delegate
                app.setActivationPolicy(.accessory)
                withExtendedLifetime(delegate) { app.run() }
            }
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
    /// `switchedOff` shows it as it looks with automatic switching off, without touching the saved setting.
    @MainActor
    private static func snapshot(to path: String, switchedOff: Bool) {
        _ = NSApplication.shared
        let controller = PowerController(monitor: false)
        if switchedOff {
            controller.persistsChanges = false
            controller.enabled = false
        }
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

/// Owns the menu bar item and its popover. A popover sized from the SwiftUI content follows the
/// content's height as status lines come and go; MenuBarExtra's window kept its tallest size.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = PowerController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var iconUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: ContentView(controller: controller))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        updateIcon()
        // objectWillChange fires before the new values are set, so read them on the next turn.
        iconUpdates = controller.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: controller.menuSymbol, accessibilityDescription: "Power Modes")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // An accessory app is not active when its menu bar item is clicked; without this the
            // popover does not take key focus or close on an outside click.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
