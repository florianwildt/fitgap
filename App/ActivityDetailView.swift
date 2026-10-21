import FITgapCore
import SwiftUI

/// Read-only summary of the cached session metrics; values missing in the FIT are hidden.
struct ActivityDetailView: View {
    @ObservedObject var model: AppModel
    let initial: ActivityRecord

    // Follow the live record so recalculated metrics or a new sharing mark appear immediately.
    private var activity: ActivityRecord { model.activities.first { $0.key == initial.key } ?? initial }
    private var metrics: ActivityMetrics? { activity.metrics }

    var body: some View {
        List {
            Section {
                row("Sportart", sport)
                row("Start", activity.date?.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                row("Quelle", activity.source.title)
            }
            Section {
                if let ascent = metrics?.ascentMeters, let descent = metrics?.descentMeters {
                    LabeledContent("Höhenmeter", value: "↑ \(ActivityFormat.meters(ascent)) / ↓ \(ActivityFormat.meters(descent))")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Höhenmeter: Anstieg \(ActivityFormat.meters(ascent)), Abstieg \(ActivityFormat.meters(descent))")
                } else {
                    row("Anstieg", metrics?.ascentMeters.map(ActivityFormat.meters))
                    row("Abstieg", metrics?.descentMeters.map(ActivityFormat.meters))
                }
                if let low = metrics?.minimumAltitudeMeters, let high = metrics?.maximumAltitudeMeters {
                    row("Höhe", "\(ActivityFormat.meters(low)) – \(ActivityFormat.meters(high))")
                }
            }
            Section {
                row("Strecke", ActivityFormat.distance(metrics?.distanceMeters))
                row("Dauer", (metrics?.timerSeconds ?? activity.duration).map(ActivityFormat.duration))
                if let elapsed = metrics?.elapsedSeconds, abs(elapsed - (metrics?.timerSeconds ?? elapsed)) >= 1 {
                    row("Gesamtzeit", ActivityFormat.duration(elapsed))
                }
                row("Ø Geschwindigkeit", ActivityFormat.speed(metrics?.averageSpeedMetersPerSecond))
                row("Max. Geschwindigkeit", ActivityFormat.speed(metrics?.maximumSpeedMetersPerSecond))
                row("Kalorien", metrics?.energyKilocalories.map { ActivityFormat.integer($0) + " kcal" })
            } footer: {
                if metrics == nil { Text("Kennzahlen erscheinen, sobald die FIT-Datei offline verfügbar ist.") }
            }
            Section {
                row("Ø Herzfrequenz", metrics?.averageHeartRate.map(heartRate))
                row("Max. Herzfrequenz", metrics?.maximumHeartRate.map(heartRate))
                row("Ø Trittfrequenz", metrics?.averageCadence.map(cadence))
                row("Max. Trittfrequenz", metrics?.maximumCadence.map(cadence))
                row("Ø Leistung", metrics?.averagePowerWatts.map { ActivityFormat.integer($0) + " W" })
                row("Max. Leistung", metrics?.maximumPowerWatts.map { ActivityFormat.integer($0) + " W" })
            }
            Section {
                if activity.status != .available { row("Datei", activity.status.title) }
                row("Zuletzt geteilt", activity.sharedAt?.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(activity.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value { LabeledContent(title, value: value) }
    }

    private func heartRate(_ value: Double) -> String { String(localized: "\(Int(value.rounded())) S/min") }
    private func cadence(_ value: Double) -> String { String(localized: "\(Int(value.rounded())) U/min") }

    /// FIT `sport`/`sub_sport` values (Garmin FIT Global Profile); unknown values stay hidden.
    private var sport: String? {
        switch (metrics?.sport, metrics?.subSport) {
        case (2, 6): String(localized: "Indoor-Radfahren")
        case (2, 58): String(localized: "Virtuelles Radfahren")
        case (2, _): String(localized: "Radfahren")
        case (1, _): String(localized: "Laufen")
        case (5, _): String(localized: "Schwimmen")
        case (11, _): String(localized: "Gehen")
        case (17, _): String(localized: "Wandern")
        case (15, _): String(localized: "Rudern")
        case (4, _): String(localized: "Fitnessgerät")
        case (10, _): String(localized: "Training")
        default: nil
        }
    }
}

/// Shared formatting for activity rows and details.
enum ActivityFormat {
    static func integer(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
    static func meters(_ value: Double) -> String { integer(value) + " m" }

    static func distance(_ meters: Double?) -> String? {
        meters.map { ($0 / 1000).formatted(.number.precision(.fractionLength(2))) + " km" }
    }
    static func speed(_ metersPerSecond: Double?) -> String? {
        metersPerSecond.map { ($0 * 3.6).formatted(.number.precision(.fractionLength(2))) + " km/h" }
    }
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return String(localized: "unbekannt") }
        return Duration.seconds(seconds.rounded()).formatted(.time(pattern: .hourMinuteSecond))
    }
}
