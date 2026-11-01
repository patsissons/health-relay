#if os(iOS)
import HealthKit
import Testing
@testable import HealthDataRelayKit

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

    @Test func everyMetricUnitFitsItsType() {
        for m in MetricCatalog.metrics {
            for id in m.identifiers where !m.isCategory && LiveHealthStore.quantityType(id) != nil {
                #expect(LiveHealthStore.resolve(id, unit: m.unit) != nil, "\(m.name) in \(m.unit)")
                for choice in m.dimension.choices {
                    #expect(LiveHealthStore.resolve(id, unit: choice) != nil, "\(m.name) in \(choice)")
                }
            }
        }
        for s in MetricCatalog.workoutStatistics where LiveHealthStore.quantityType(s.id) != nil {
            #expect(LiveHealthStore.resolve(s.id, unit: s.unit) != nil, "\(s.name)")
        }
    }

    @Test func everyMetricIsReadTheWayItsTypeAggregates() {
        for m in MetricCatalog.metrics where !m.isCategory {
            guard let qt = LiveHealthStore.quantityType(m.identifiers[0]) else { continue }
            #expect((qt.aggregationStyle == .cumulative) == (m.form == .total), "\(m.name)")
        }
    }

    @Test func everyEventAndMetricTypeExists() {
        let missing = MetricCatalog.allTypes.filter { LiveHealthStore.sampleType($0) == nil }.map(\.id)
        // On this SDK's simulator every identifier resolves except any newer than it.
        #expect(missing.isEmpty, "\(missing)")
    }

    /// HealthKit raises an uncatchable exception for a type it won't let an app
    /// ask for in the general request, and doses are one: they come with the
    /// per-medication sheet. The app's real request is exercised by the UI test
    /// testValuesByDayMatchWhatWasWritten, which needs the app's entitlement.
    @Test func dosesStayOutOfTheGeneralRequest() {
        let types = LiveHealthStore.objectTypes(MetricCatalog.allTypes, extras: [.routes, .heartbeats, .stateOfMind, .medications])
        #expect(types.count > 100)
        if #available(iOS 26.0, *) { #expect(!types.contains(HKObjectType.medicationDoseEventType())) }
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
