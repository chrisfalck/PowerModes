import Foundation
import IOKit.ps
import PowerPolicy

struct BatteryState: Equatable {
    let source: PowerSource
    let percent: Int
}

struct CommandResult {
    let status: Int32
    let output: String
    let errorOutput: String
}

enum SystemPower {
    /// Root-owned helper; `scripts/install-helper.sh` installs it with a sudoers rule limited to its mode commands.
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.chrisfalck.powermodes.helper"
    static let powerSourceChanged = Notification.Name("PowerModesPowerSourceChanged")

    /// Charge and source as `pmset -g batt` reports them. Nil without an internal battery or on UPS power.
    static func batteryState() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?,
              let source = PowerSource.allCases.first(where: { $0.profileName == providing }) else { return nil }
        for item in list {
            guard let info = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let percent = current * 100 / maximum
            return (0...100).contains(percent) ? BatteryState(source: source, percent: percent) : nil
        }
        return nil
    }

    /// Posts `powerSourceChanged` on the main thread whenever charge or power source changes.
    static func startPowerSourceNotifications() {
        let callback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: SystemPower.powerSourceChanged, object: nil)
        }
        guard let loopSource = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .defaultMode)
    }

    static func currentModes() -> [PowerSource: PowerMode] {
        let result = run("/usr/bin/pmset", ["-g", "custom"], timeout: 10)
        return result.status == 0 ? Policy.parseCustomModes(result.output) : [:]
    }

    /// The profile in use switches with the display's brightness locked; the other one is a plain `pmset`.
    static func apply(_ change: ModeChange, active: PowerSource) -> CommandResult {
        let verb = change.source == active ? "--switch" : "--set"
        return run("/usr/bin/sudo", ["-n", helperPath, verb, change.source.pmsetFlag, String(change.mode.rawValue)], timeout: 30)
    }

    /// True when the helper is installed and the sudoers rule lets this user run it without a password.
    static func helperReady() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { return false }
        return run("/usr/bin/sudo", ["-n", "-l", helperPath, "--set", "c", "0"], timeout: 10).status == 0
    }

    /// Runs the bundled install script as root through the macOS administrator prompt.
    /// Returns nil on success or if the user cancelled, otherwise what went wrong.
    static func installHelper() -> String? {
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else {
            return "This copy of the app has no bundled installer. Run scripts/install-helper.sh with sudo."
        }
        // Arguments reach AppleScript through argv, so no path needs escaping into the script text.
        let result = run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script \"/bin/sh \" & quoted form of item 1 of argv & \" --no-restart --user \" & quoted form of item 2 of argv with prompt \"Power Modes needs to install its helper to change power modes.\" with administrator privileges",
            "-e", "end run",
            script, NSUserName(),
        ], timeout: 600)
        if result.status == 0 { return nil }
        let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.contains("-128") ? nil : "Helper install failed" + (detail.isEmpty ? "." : ": \(detail)")
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(status: -1, output: "", errorOutput: error.localizedDescription) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Outputs here are a few lines, well under the pipe buffer, so reading after exit cannot deadlock.
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, output: output, errorOutput: errorOutput)
    }
}

enum ActivityLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Power Modes.log")

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
