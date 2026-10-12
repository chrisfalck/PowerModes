import Foundation

/// macOS power modes, numbered as `pmset powermode` numbers them.
public enum PowerMode: Int, Codable, Sendable, CaseIterable {
    case automatic = 0
    case low = 1
    case high = 2

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .low: return "Low Power"
        case .high: return "High Power"
        }
    }
}

public enum PowerSource: String, Codable, Sendable, CaseIterable {
    case ac
    case battery

    /// Section heading in `pmset -g custom`, and the name `pmset -g batt` reports.
    public var profileName: String { self == .ac ? "AC Power" : "Battery Power" }
    /// `pmset -c` / `pmset -b`.
    public var pmsetFlag: String { self == .ac ? "c" : "b" }
}

/// Charge thresholds for one power source.
/// At or above `highMin` is High Power, at or above `autoMin` is Automatic, anything lower is Low Power.
public struct Thresholds: Codable, Equatable, Sendable {
    public static let highRange = 1...101
    public static let autoRange = 0...100
    /// `highMin` value meaning High Power is never used.
    public static let never = 101

    public private(set) var highMin: Int
    public private(set) var autoMin: Int

    public init(highMin: Int, autoMin: Int) {
        self.highMin = Self.never
        self.autoMin = 0
        setAutoMin(autoMin)
        setHighMin(max(highMin, self.autoMin))
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(highMin: try values.decode(Int.self, forKey: .highMin),
                  autoMin: try values.decode(Int.self, forKey: .autoMin))
    }

    public var usesHighPower: Bool { highMin < Self.never }

    /// Moving one threshold past the other drags the other along, so `autoMin <= highMin` always holds.
    public mutating func setHighMin(_ value: Int) {
        highMin = min(max(value, Self.highRange.lowerBound), Self.highRange.upperBound)
        autoMin = min(autoMin, highMin)
    }

    public mutating func setAutoMin(_ value: Int) {
        autoMin = min(max(value, Self.autoRange.lowerBound), Self.autoRange.upperBound)
        highMin = max(highMin, autoMin)
    }

    public func mode(at percent: Int) -> PowerMode {
        if percent >= highMin { return .high }
        if percent >= autoMin { return .automatic }
        return .low
    }
}

public struct PolicySettings: Codable, Equatable, Sendable {
    public var ac: Thresholds
    public var battery: Thresholds

    public init(ac: Thresholds, battery: Thresholds) {
        self.ac = ac
        self.battery = battery
    }

    /// The thresholds a fresh install starts with.
    public static let defaults = PolicySettings(
        ac: Thresholds(highMin: 80, autoMin: 21),
        battery: Thresholds(highMin: Thresholds.never, autoMin: 51))

    public subscript(source: PowerSource) -> Thresholds {
        get { source == .ac ? ac : battery }
        set { if source == .ac { ac = newValue } else { battery = newValue } }
    }
}

public struct ModeChange: Equatable, Sendable {
    public let source: PowerSource
    public let mode: PowerMode

    public init(source: PowerSource, mode: PowerMode) {
        self.source = source
        self.mode = mode
    }
}

public enum Policy {
    /// Changes needed so both profiles match the settings at this charge.
    /// Both profiles are kept current so plugging in or unplugging lands in the right mode at once.
    /// The profile in use comes last so a failure there cannot leave the other one stale.
    public static func plan(percent: Int, active: PowerSource, settings: PolicySettings,
                            current: [PowerSource: PowerMode]) -> [ModeChange] {
        let order: [PowerSource] = active == .ac ? [.battery, .ac] : [.ac, .battery]
        return order.compactMap { source in
            let desired = settings[source].mode(at: percent)
            return current[source] == desired ? nil : ModeChange(source: source, mode: desired)
        }
    }

    /// Reads each profile's `powermode` out of `pmset -g custom`.
    public static func parseCustomModes(_ output: String) -> [PowerSource: PowerMode] {
        var modes: [PowerSource: PowerMode] = [:]
        var section: PowerSource?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if let first = line.first, first != " ", first != "\t" {
                section = PowerSource.allCases.first { line == $0.profileName + ":" }
                continue
            }
            guard let section else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 2, fields[0] == "powermode", let raw = Int(fields[1]), let mode = PowerMode(rawValue: raw) {
                modes[section] = mode
            }
        }
        return modes
    }
}
