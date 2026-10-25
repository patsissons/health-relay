#if os(iOS)
import HealthKit
import Testing
@testable import HealthRelayKit

/// The catalog against the real HealthKit (run on a simulator): every unit
/// string parses and fits its type, since HealthKit raises on a bad one.
@Suite struct LiveCatalogTests {
    @Test func everyUnitFitsItsType() {
        for t in Catalog.stats where LiveHealthStore.quantityType(t.id) != nil {
            #expect(LiveHealthStore.resolve(t.id, unit: t.healthKitUnit) != nil, "\(t.id) in \(t.healthKitUnit)")
        }
        for s in Catalog.samples {
            guard case .quantity(_, let unit) = s.value, LiveHealthStore.quantityType(s.id) != nil else { continue }
            #expect(LiveHealthStore.resolve(s.id, unit: unit) != nil, "\(s.id) in \(unit)")
        }
        for id in Catalog.workoutDistances where LiveHealthStore.quantityType(id) != nil {
            #expect(LiveHealthStore.resolve(id, unit: "km") != nil, "\(id)")
        }
    }

    @Test func theCoreTypesExist() {
        let missing = Catalog.allTypes.filter { LiveHealthStore.sampleType($0) == nil }.map(\.id)
        // Only identifiers newer than this OS may be missing.
        for id in ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate", "HKCategoryTypeIdentifierSleepAnalysis",
                   "HKQuantityTypeIdentifierBodyMass", "HKCategoryTypeIdentifierHeadache"] {
            #expect(!missing.contains(id))
        }
        print("types this iOS does not have:", missing)
    }

    @Test func sumTypesAreCumulativeAndTheRestDiscrete() {
        for t in Catalog.stats {
            guard let qt = LiveHealthStore.quantityType(t.id) else { continue }
            #expect((qt.aggregationStyle == .cumulative) == (t.mode == .sum), "\(t.id)")
        }
    }
}
#endif
