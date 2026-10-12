import SwiftUI
import PowerPolicy

extension PowerMode {
    var color: Color {
        switch self {
        case .low: return .green
        case .automatic: return .blue
        case .high: return .orange
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: PowerController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(PowerSource.allCases, id: \.self) { source in
                SourceSection(source: source, controller: controller)
            }
            Divider()
            Toggle("Switch modes automatically", isOn: $controller.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if let problem = controller.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastChange = controller.lastChange {
                Text("Last change: \(lastChange)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reset to Defaults") { controller.resetToDefaults() }
                    .disabled(controller.settings == .defaults)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Power Modes").font(.headline)
            if let battery = controller.battery {
                Text("\(battery.source.profileName) · \(battery.percent)% · \(controller.activeMode?.label ?? "Unknown mode")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No battery found").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SourceSection: View {
    let source: PowerSource
    @ObservedObject var controller: PowerController

    private var thresholds: Thresholds { controller.settings[source] }
    private var isActive: Bool { controller.battery?.source == source }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("On \(source.profileName)").font(.subheadline.weight(.semibold))
                if isActive {
                    Text("In use")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let mode = controller.modes[source] {
                    Text(mode.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            ZoneBar(thresholds: thresholds, percent: controller.battery?.percent)
            ThresholdSlider(
                title: "High Power from",
                value: thresholds.usesHighPower ? "\(thresholds.highMin)%" : "Never",
                tint: PowerMode.high.color,
                range: Thresholds.highRange,
                position: Binding(
                    get: { thresholds.highMin },
                    set: { controller.settings[source].setHighMin($0) }))
            ThresholdSlider(
                title: "Automatic from",
                value: "\(thresholds.autoMin)%",
                tint: PowerMode.automatic.color,
                range: Thresholds.autoRange,
                position: Binding(
                    get: { thresholds.autoMin },
                    set: { controller.settings[source].setAutoMin($0) }))
            Text(thresholds.autoMin == 0 ? "Low Power is never used" : "Low Power below \(thresholds.autoMin)%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ThresholdSlider: View {
    let title: String
    let value: String
    let tint: Color
    let range: ClosedRange<Int>
    @Binding var position: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            // No `step:` so the track stays free of a hundred tick marks; whole percents come from rounding.
            Slider(value: Binding(get: { Double(position) }, set: { position = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .tint(tint)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }
}

/// The 0–100% charge range coloured by the mode each part gets, with a marker at the current charge.
private struct ZoneBar: View {
    let thresholds: Thresholds
    let percent: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let autoStart = width * CGFloat(thresholds.autoMin) / 100
            let highStart = width * CGFloat(min(thresholds.highMin, 100)) / 100
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    PowerMode.low.color.frame(width: autoStart)
                    PowerMode.automatic.color.frame(width: max(0, highStart - autoStart))
                    PowerMode.high.color
                        .opacity(thresholds.usesHighPower ? 1 : 0)
                }
                .opacity(0.75)
                .clipShape(Capsule())
                if let percent {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: geometry.size.height + 6)
                        .offset(x: min(max(width * CGFloat(percent) / 100 - 1.5, 0), width - 3))
                }
            }
        }
        .frame(height: 8)
        .padding(.vertical, 3)
        .accessibilityHidden(true)
    }
}
