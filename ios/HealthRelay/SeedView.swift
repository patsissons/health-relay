#if DEBUG && targetEnvironment(simulator)
import CoreLocation
import HealthKit
import HealthRelayKit
import SwiftUI

/// Debug builds only: writes a week of plausible synthetic samples so the
/// app can be tried on a simulator, which has no Health data of its own.
struct SeedView: View {
    @Environment(AppModel.self) private var model
    @State private var status = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        working = true
                        Task {
                            status = await Seeder(store: model.health.healthStore).seed(days: 7)
                            working = false
                        }
                    } label: {
                        HStack {
                            Label("Seed the last 7 days", systemImage: "leaf")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("seed")
                    if !status.isEmpty {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("seed-status")
                    }
                } footer: {
                    Text("Writes steps, energy, heart rate, HRV, weight, sleep, mindful minutes, blood pressure, sound levels, a symptom and runs with routes. Samples are marked as written by Health Relay.")
                }
            }
            .navigationTitle("Seed")
        }
    }
}

/// Writes the synthetic samples. Deterministic: the same day gets the same values.
struct Seeder {
    let store: HKHealthStore

    static var shareTypes: Set<HKSampleType> {
        let q: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .distanceWalkingRunning, .heartRate, .restingHeartRate,
                                             .heartRateVariabilitySDNN, .bodyMass, .bloodPressureSystolic, .bloodPressureDiastolic,
                                             .environmentalAudioExposure]
        var types = Set<HKSampleType>(q.map { HKQuantityType($0) })
        types.formUnion([HKCategoryType(.sleepAnalysis), HKCategoryType(.mindfulSession), HKCategoryType(.headache),
                         HKObjectType.workoutType(), HKSeriesType.workoutRoute()])
        return types
    }

    func seed(days: Int) async -> String {
        do {
            try await store.requestAuthorization(toShare: Self.shareTypes, read: LiveHealthStore.readTypes)
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            var count = 0
            for back in (0..<days).reversed() {
                let day = calendar.date(byAdding: .day, value: -back, to: today)!
                count += try await seedDay(day, index: back)
            }
            return "Wrote \(count) samples over \(days) days"
        } catch {
            return "Could not write: \(error.localizedDescription)"
        }
    }

    private func at(_ day: Date, _ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }

    /// One day's samples; nothing later than now.
    private func seedDay(_ day: Date, index n: Int) async throws -> Int {
        var samples: [HKSample] = []
        let now = Date()
        func quantity(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ start: Date, _ end: Date? = nil) {
            let end = end ?? start
            guard end <= now else { return }
            samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end))
        }
        func category(_ id: HKCategoryTypeIdentifier, _ value: Int, _ start: Date, _ end: Date) {
            guard end <= now else { return }
            samples.append(HKCategorySample(type: HKCategoryType(id), value: value, start: start, end: end))
        }
        let wobble = Double((n * 37) % 11) - 5
        for hour in stride(from: 8.0, to: 21, by: 1) {
            quantity(.stepCount, .count(), 500 + 40 * wobble + hour * 20, at(day, hour), at(day, hour + 0.9))
            quantity(.activeEnergyBurned, .kilocalorie(), 28 + wobble, at(day, hour), at(day, hour + 0.9))
            quantity(.distanceWalkingRunning, .meterUnit(with: .kilo), 0.4 + wobble / 100, at(day, hour), at(day, hour + 0.9))
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for minute in stride(from: 0.0, to: 24 * 60, by: 10) {
            let h = minute / 60
            quantity(.heartRate, bpm, (h < 7 ? 56 : 72) + wobble + 6 * sin(h), at(day, h))
        }
        quantity(.restingHeartRate, bpm, 58 + wobble / 2, at(day, 7))
        for h in [2.0, 4.0, 6.0] { quantity(.heartRateVariabilitySDNN, .secondUnit(with: .milli), 42 + wobble * 2 + h, at(day, h)) }
        quantity(.bodyMass, .gramUnit(with: .kilo), 80.4 - Double(6 - n) * 0.1, at(day, 7.2))
        for (h, db) in [(9.0, 62.0), (12.5, 74.0), (18.0, 68.0)] {
            quantity(.environmentalAudioExposure, .decibelAWeightedSoundPressureLevel(), db + wobble, at(day, h), at(day, h + 0.5))
        }
        let reading = at(day, 8.1)
        if n % 2 == 0, reading <= now {
            let sys = HKQuantitySample(type: HKQuantityType(.bloodPressureSystolic), quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 121 + wobble), start: reading, end: reading)
            let dia = HKQuantitySample(type: HKQuantityType(.bloodPressureDiastolic), quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 79 + wobble / 2), start: reading, end: reading)
            samples.append(HKCorrelation(type: HKCorrelationType(.bloodPressure), start: reading, end: reading, objects: [sys, dia]))
        }
        // Last night, ending this morning.
        var t = at(day, -1.2)
        for (stage, minutes) in [(HKCategoryValueSleepAnalysis.asleepCore, 120.0), (.asleepDeep, 60), (.awake, 10), (.asleepCore, 110), (.asleepREM, 90), (.awake, 10)] {
            let end = t.addingTimeInterval(minutes * 60)
            category(.sleepAnalysis, stage.rawValue, t, end)
            t = end
        }
        if n % 3 == 0 { category(.mindfulSession, HKCategoryValue.notApplicable.rawValue, at(day, 21), at(day, 21.2)) }
        if n == 2 { category(.headache, HKCategoryValueSeverity.mild.rawValue, at(day, 15), at(day, 15)) }
        var written = try await save(samples)
        if n % 2 == 1, at(day, 17.75) <= now { written += try await run(day, index: n) }
        return written
    }

    private func save(_ samples: [HKSample]) async throws -> Int {
        guard !samples.isEmpty else { return 0 }
        try await store.save(samples)
        return samples.count
    }

    /// A 40-minute run at 17:00 with a route around a park.
    private func run(_ day: Date, index n: Int) async throws -> Int {
        let start = at(day, 17)
        let end = at(day, 17 + 40.0 / 60)
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        try await builder.beginCollection(at: start)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = [
            HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 380 + Double(n) * 5), start: start, end: end),
            HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning), quantity: HKQuantity(unit: .meterUnit(with: .kilo), doubleValue: 6.2 + Double(n) / 10), start: start, end: end),
        ]
        for minute in stride(from: 0.0, to: 40, by: 1) {
            let t = start.addingTimeInterval(minute * 60)
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: bpm, doubleValue: 135 + minute / 2), start: t, end: t))
        }
        try await builder.addSamples(samples)
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return 0 }
        let route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        var points: [CLLocation] = []
        for i in 0..<240 {
            let a = Double(i) / 240 * 2 * .pi
            let t = start.addingTimeInterval(Double(i) * 10)
            points.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 49.2965 + 0.006 * sin(a), longitude: -123.1360 + 0.012 * cos(a)),
                                     altitude: 12 + 8 * sin(a * 2), horizontalAccuracy: 5, verticalAccuracy: 3, course: -1, speed: 2.6, timestamp: t))
        }
        try await route.insertRouteData(points)
        try await route.finishRoute(with: workout, metadata: nil)
        return samples.count + 1
    }
}
#endif
