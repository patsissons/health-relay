import Foundation
import Testing
@testable import HealthRelayKit

/// The synthetic data behind fixtures/push-two-days.json, read and encoded
/// as the app does, must be the fixture byte for byte.
@Suite struct FixtureTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    static let device = Device(name: "Test iPhone", model: "iPhone17,1", os: "26.0", app: "Health Relay 0.1")

    static func store() -> FakeHealthStore {
        let s = FakeHealthStore()
        let q = "HKQuantityTypeIdentifier"
        let c = "HKCategoryTypeIdentifier"
        let d = T.date

        // 2026-10-24 statistics, two sources each.
        s.add(q + "StepCount", source: "iPhone", d("2026-10-24 09:00:00 -0700"), d("2026-10-24 10:00:00 -0700"), 5000)
        s.add(q + "StepCount", source: "iPhone", d("2026-10-24 13:00:00 -0700"), d("2026-10-24 14:00:00 -0700"), 3000)
        s.add(q + "StepCount", source: "Watch", d("2026-10-24 08:00:00 -0700"), d("2026-10-24 18:00:00 -0700"), 9500)
        // Heart rate: Watch 200 readings averaging 70 (48 to 150), chest strap 100 averaging 130 (90 to 170).
        let watchHR = [48.0, 150] + Array(repeating: 69.0, count: 58) + Array(repeating: 70.0, count: 140)
        for (i, v) in watchHR.enumerated() {
            s.add(q + "HeartRate", source: "Watch", d("2026-10-24 00:05:00 -0700").addingTimeInterval(Double(i) * 300), v)
        }
        let strapHR = [90.0, 170] + Array(repeating: 130.0, count: 98)
        for (i, v) in strapHR.enumerated() {
            s.add(q + "HeartRate", source: "Chest strap", d("2026-10-24 17:00:00 -0700").addingTimeInterval(Double(i) * 20), v)
        }
        for h in ["03", "04", "05"] {
            s.add(q + "HeartRateVariabilitySDNN", source: "Watch", d("2026-10-24 \(h):00:00 -0700"), 40)
        }
        s.add(q + "HeartRateVariabilitySDNN", source: "Watch 2", d("2026-10-24 06:00:00 -0700"), 60)
        s.add(q + "BodyMass", source: "Withings", d("2026-10-24 07:10:00 -0700"), 80)
        s.add(q + "BodyMass", source: "Manual", d("2026-10-24 06:00:00 -0700"), 81)
        // 2026-10-25
        s.add(q + "ActiveEnergyBurned", source: "Watch", d("2026-10-25 06:00:00 -0700"), d("2026-10-25 13:00:00 -0700"), 512.4)

        // Samples
        s.addCategory(c + "SleepAnalysis", source: "Watch", d("2026-10-23 23:10:00 -0700"), d("2026-10-24 02:00:00 -0700"), 3)
        s.addCategory(c + "SleepAnalysis", source: "Watch", d("2026-10-24 02:00:00 -0700"), d("2026-10-24 03:00:00 -0700"), 4)
        s.addCategory(c + "SleepAnalysis", source: "Watch", d("2026-10-24 03:00:00 -0700"), d("2026-10-24 06:40:00 -0700"), 5)
        s.addCategory(c + "AppleStandHour", source: "Watch", d("2026-10-24 09:00:00 -0700"), d("2026-10-24 10:00:00 -0700"), 0)
        s.addCategory(c + "AppleStandHour", source: "Watch", d("2026-10-24 10:00:00 -0700"), d("2026-10-24 11:00:00 -0700"), 1)
        s.add(q + "EnvironmentalAudioExposure", source: "Watch", d("2026-10-25 12:00:00 -0700"), d("2026-10-25 12:30:00 -0700"), 60)
        s.add(q + "EnvironmentalAudioExposure", source: "Watch", d("2026-10-25 12:30:00 -0700"), d("2026-10-25 13:30:00 -0700"), 90)
        s.add(q + "BloodPressureSystolic", source: "Cuff", d("2026-10-25 08:00:00 -0700"), 121)
        s.add(q + "BloodPressureDiastolic", source: "Cuff", d("2026-10-25 08:00:00 -0700"), 79)
        s.addCategory(c + "Headache", source: "iPhone", d("2026-10-25 15:00:00 -0700"), 2)
        s.addCategory(c + "MindfulSession", source: "iPhone", d("2026-10-25 20:00:00 -0700"), d("2026-10-25 20:12:00 -0700"), 0)
        s.add(q + "WorkoutEffortScore", source: "Watch", d("2026-10-24 17:40:00 -0700"), 7)

        s.add(WorkoutRecord(
            activityType: "HKWorkoutActivityTypeRunning", source: "Watch",
            start: d("2026-10-24 17:00:00 -0700"), end: d("2026-10-24 17:45:00 -0700"), duration: 2700,
            statistics: [
                .init(type: q + "ActiveEnergyBurned", unit: "kcal", sum: 420),
                .init(type: q + "DistanceWalkingRunning", unit: "km", sum: 7.5),
                .init(type: q + "HeartRate", unit: "count/min", average: 151.4, maximum: 172),
            ],
            route: [
                .init(lat: 49.28, lon: -123.12, ele: 10),
                .init(lat: 49.281, lon: -123.121, ele: 14),
                .init(lat: 49.283, lon: -123.125, ele: 22),
                .init(lat: 49.284, lon: -123.13, ele: 12),
            ]))
        s.add(ActivitySummaryRecord(day: T.day("2026-10-24"), standHours: 11, moveGoal: 600))
        // Two seconds of 512 Hz trace; the app sends it at 128 Hz.
        s.add(ECGRecord(start: d("2026-10-25 09:00:00 -0700"), classification: "Sinus Rhythm", rate: 512, averageHeartRate: 61,
                        voltages: (0..<1024).map { jsRound(200 * sin(Double($0) / 20)) }))
        return s
    }

    @Test func twoDaysEqualTheFixture() async throws {
        let calendar = Calendar.local(T.vancouver)
        let days = [T.day("2026-10-24"), T.day("2026-10-25")]
        let read = try await DayReader(store: Self.store(), calendar: calendar).read(days)
        let push = Push(device: Self.device, exportedAt: T.date("2026-10-25 07:00:00 -0700"), timeZone: T.vancouver,
                        days: days, content: .merging(days.map { read[$0]! }))
        let want = try String(contentsOf: Self.fixtures.appendingPathComponent("push-two-days.json"), encoding: .utf8)
        let got = String(decoding: push.body, as: UTF8.self)
        if got != want {
            let prefix = zip(got, want).prefix { $0 == $1 }.count
            Issue.record("differs at \(prefix): got …\(got.dropFirst(max(0, prefix - 80)).prefix(200))… want …\(want.dropFirst(max(0, prefix - 80)).prefix(200))…")
        }
    }

    @Test func emptyPushEqualsTheFixture() throws {
        let push = Push.empty(device: Self.device, at: T.date("2026-10-25 07:00:00 -0700"), timeZone: T.vancouver)
        let want = try String(contentsOf: Self.fixtures.appendingPathComponent("empty-push.json"), encoding: .utf8)
        #expect(String(decoding: push.body, as: UTF8.self) == want)
    }
}
