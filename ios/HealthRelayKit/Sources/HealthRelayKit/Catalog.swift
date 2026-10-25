import Foundation

/// How a quantity type's day is summarized in `stats` (docs/schema.md).
public enum StatMode: String, Sendable, Codable {
    /// `sum`: the source's total for the day.
    case sum
    /// `avg` + `count`: the mean of the day's samples.
    case mean
    /// `avg` + `count` + `min` + `max` (heart rate).
    case hr
    /// `latest` + `latestAt`: the day's most recent value.
    case last
}

/// How often the health store may wake the app for a type.
public enum WakeFrequency: Sendable {
    case hourly
    case daily
}

/// A type the app reads, by its HealthKit identifier string.
public struct HealthType: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        case quantity
        case category
        case workout
        case ecg
    }

    public let kind: Kind
    public let id: String

    public init(_ kind: Kind, _ id: String) {
        self.kind = kind
        self.id = id
    }

    public static let workout = HealthType(.workout, "HKWorkoutTypeIdentifier")
    public static let ecg = HealthType(.ecg, "HKDataTypeIdentifierElectrocardiogram")

    public var description: String { id }
}

/// A quantity type summarized per day and source in `stats`.
public struct StatType: Sendable {
    public let id: String
    public let mode: StatMode
    /// The unit string sent, in export.xml spelling.
    public let unit: String
    /// The HKUnit string to read the value in, when it differs from `unit`.
    public let healthKitUnit: String

    init(_ id: String, _ mode: StatMode, _ unit: String, healthKit: String? = nil) {
        self.id = "HKQuantityTypeIdentifier" + id
        self.mode = mode
        self.unit = unit
        healthKitUnit = healthKit ?? unit
    }

    public var type: HealthType { HealthType(.quantity, id) }
}

/// A type sent sample by sample in `samples`.
public struct SampleType: Sendable {
    public enum Value: Sendable {
        /// A quantity in a unit (sent and HKUnit strings).
        case quantity(unit: String, healthKitUnit: String)
        /// A category value, sent by its HealthKit name.
        case category
    }

    public let id: String
    public let value: Value
    public let frequency: WakeFrequency

    static func quantity(_ id: String, _ unit: String) -> SampleType {
        SampleType(id: "HKQuantityTypeIdentifier" + id, value: .quantity(unit: unit, healthKitUnit: unit), frequency: .hourly)
    }

    static func category(_ id: String, _ frequency: WakeFrequency = .hourly) -> SampleType {
        SampleType(id: "HKCategoryTypeIdentifier" + id, value: .category, frequency: frequency)
    }

    public var type: HealthType {
        switch value {
        case .quantity: HealthType(.quantity, id)
        case .category: HealthType(.category, id)
        }
    }
}

/// Everything the app reads. The quantity table mirrors the reference
/// receiver's (cubby's pb_public/health/apple.js QUANTITY and MICRO), so
/// every type it maps is sent. A type the running OS does not know is
/// skipped at read time, so newer types need no availability checks here.
public enum Catalog {
    public static let stats: [StatType] = [
        // Activity
        StatType("StepCount", .sum, "count"),
        StatType("DistanceWalkingRunning", .sum, "km"),
        StatType("ActiveEnergyBurned", .sum, "kcal"),
        StatType("BasalEnergyBurned", .sum, "kcal"),
        StatType("AppleExerciseTime", .sum, "min"),
        StatType("FlightsClimbed", .sum, "count"),
        StatType("AppleStandTime", .sum, "min"),
        StatType("PhysicalEffort", .mean, "kcal/hr·kg", healthKit: "kcal/(kg*hr)"),
        StatType("DistanceCycling", .sum, "km"),
        StatType("DistanceRowing", .sum, "km"),
        StatType("RowingSpeed", .mean, "km/hr"),
        StatType("NumberOfTimesFallen", .sum, "count"),
        StatType("TimeInDaylight", .sum, "min"),
        // Mobility
        StatType("WalkingSpeed", .mean, "km/hr"),
        StatType("WalkingStepLength", .mean, "cm"),
        StatType("WalkingDoubleSupportPercentage", .mean, "%"),
        StatType("WalkingAsymmetryPercentage", .mean, "%"),
        StatType("AppleWalkingSteadiness", .last, "%"),
        StatType("StairAscentSpeed", .mean, "m/s"),
        StatType("StairDescentSpeed", .mean, "m/s"),
        StatType("SixMinuteWalkTestDistance", .last, "m"),
        // Heart and lungs
        StatType("HeartRate", .hr, "count/min"),
        StatType("RestingHeartRate", .mean, "count/min"),
        StatType("WalkingHeartRateAverage", .mean, "count/min"),
        StatType("HeartRateVariabilitySDNN", .mean, "ms"),
        StatType("HeartRateVariabilityRMSSD", .mean, "ms"),
        StatType("HeartRateRecoveryOneMinute", .mean, "count/min"),
        StatType("VO2Max", .last, "mL/min·kg", healthKit: "ml/(kg*min)"),
        StatType("RespiratoryRate", .mean, "count/min"),
        StatType("OxygenSaturation", .mean, "%"),
        // Body
        StatType("BodyMass", .last, "kg"),
        StatType("BodyFatPercentage", .last, "%"),
        StatType("LeanBodyMass", .last, "kg"),
        StatType("BodyMassIndex", .last, "count"),
        StatType("Height", .last, "cm"),
        // Hearing (the exposure levels themselves go in samples)
        StatType("EnvironmentalSoundReduction", .mean, "dBASPL"),
        // Nutrition
        StatType("DietaryEnergyConsumed", .sum, "kcal"),
        StatType("DietaryProtein", .sum, "g"),
        StatType("DietaryCarbohydrates", .sum, "g"),
        StatType("DietaryFatTotal", .sum, "g"),
        StatType("DietaryFiber", .sum, "g"),
        StatType("DietarySugar", .sum, "g"),
        StatType("DietaryFatSaturated", .sum, "g"),
        StatType("DietarySodium", .sum, "mg"),
        StatType("DietaryCholesterol", .sum, "mg"),
        StatType("DietaryCaffeine", .sum, "mg"),
        StatType("DietaryWater", .sum, "mL"),
    ] + micro.map { StatType("Dietary" + $0.0, .sum, $0.1) }
    // cubby's table also maps HKDataTypeSleepDurationGoal, which is not a
    // public HealthKit type; there is nothing to read.

    /// Vitamins, minerals and fats: Dietary<suffix> and the unit sent.
    static let micro: [(String, String)] = [
        ("VitaminA", "mcg"), ("VitaminC", "mg"), ("VitaminD", "mcg"), ("VitaminE", "mg"), ("VitaminK", "mcg"),
        ("Thiamin", "mg"), ("Riboflavin", "mg"), ("Niacin", "mg"), ("PantothenicAcid", "mg"), ("VitaminB6", "mg"),
        ("Folate", "mcg"), ("VitaminB12", "mcg"), ("Calcium", "mg"), ("Iron", "mg"), ("Magnesium", "mg"),
        ("Phosphorus", "mg"), ("Potassium", "mg"), ("Zinc", "mg"), ("Copper", "mg"), ("Manganese", "mg"),
        ("Selenium", "mcg"), ("FatMonounsaturated", "g"), ("FatPolyunsaturated", "g"),
    ]

    public static let samples: [SampleType] = [
        // Quantities whose day needs each sample: sound levels (energy
        // averaged over time), blood pressure (paired by reading), wrist
        // temperature (filed under the morning it ends), effort scores
        // (matched to a workout).
        .quantity("EnvironmentalAudioExposure", "dBASPL"),
        .quantity("HeadphoneAudioExposure", "dBASPL"),
        .quantity("BloodPressureSystolic", "mmHg"),
        .quantity("BloodPressureDiastolic", "mmHg"),
        .quantity("AppleSleepingWristTemperature", "degC"),
        .quantity("WorkoutEffortScore", "appleEffortScore"),
        .quantity("EstimatedWorkoutEffortScore", "appleEffortScore"),
        .category("SleepAnalysis", .daily),
        .category("AppleStandHour", .daily),
        .category("MindfulSession", .daily),
        // HealthKit's environmental audio exposure event keeps this raw
        // identifier (it was renamed in iOS 14), as export.xml shows.
        .category("AudioExposureEvent"),
        .category("HeadphoneAudioExposureEvent"),
    ] + (severitySymptoms + presenceSymptoms).map { .category($0) }

    /// Symptom types valued by HKCategoryValueSeverity.
    static let severitySymptoms = [
        "AbdominalCramps", "Acne", "BladderIncontinence", "Bloating", "BreastPain", "ChestTightnessOrPain", "Chills",
        "Constipation", "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting", "Fatigue", "Fever",
        "GeneralizedBodyAche", "HairLoss", "Headache", "Heartburn", "HotFlashes", "LossOfSmell", "LossOfTaste",
        "LowerBackPain", "MemoryLapse", "Nausea", "NightSweats", "PelvicPain", "RapidPoundingOrFlutteringHeartbeat",
        "RunnyNose", "ShortnessOfBreath", "SinusCongestion", "SkippedHeartbeat", "SoreThroat", "VaginalDryness",
        "Vomiting", "Wheezing",
    ]

    /// Symptom types valued by HKCategoryValuePresence.
    static let presenceSymptoms = ["MoodChanges", "SleepChanges"]

    /// Distance types a workout may carry statistics for.
    public static let workoutDistances = [
        "DistanceWalkingRunning", "DistanceCycling", "DistanceSwimming", "DistanceRowing", "DistanceWheelchair",
        "DistancePaddleSports", "DistanceCrossCountrySkiing", "DistanceDownhillSnowSports", "DistanceSkatingSports",
    ].map { "HKQuantityTypeIdentifier" + $0 }

    /// Every type with samples: what the app observes, anchors and asks to read.
    public static var allTypes: [HealthType] {
        stats.map(\.type) + samples.map(\.type) + [.workout, .ecg]
    }

    public static func frequency(of type: HealthType) -> WakeFrequency {
        samples.first { $0.id == type.id }?.frequency ?? .hourly
    }

    /// A category value by its HealthKit name, as export.xml writes it.
    public static func categoryValueName(type: String, value: Int) -> String {
        let bare = type.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
        let names: [Int: String]
        let prefix: String
        switch bare {
        case "SleepAnalysis":
            prefix = "SleepAnalysis"
            names = [0: "InBed", 1: "AsleepUnspecified", 2: "Awake", 3: "AsleepCore", 4: "AsleepDeep", 5: "AsleepREM"]
        case "AppleStandHour":
            prefix = "AppleStandHour"
            names = [0: "Stood", 1: "Idle"]
        case "AudioExposureEvent":
            prefix = "AudioExposureEvent"
            names = [1: "LoudEnvironment"]
        case "HeadphoneAudioExposureEvent":
            prefix = "HeadphoneAudioExposureEvent"
            names = [1: "SevenDayLimit"]
        case _ where severitySymptoms.contains(bare):
            prefix = "Severity"
            names = [0: "Unspecified", 1: "NotPresent", 2: "Mild", 3: "Moderate", 4: "Severe"]
        case _ where presenceSymptoms.contains(bare):
            prefix = "Presence"
            names = [0: "Present", 1: "NotPresent"]
        default:
            // Mindful sessions and any other value-less category.
            return value == 0 ? "HKCategoryValueNotApplicable" : String(value)
        }
        guard let name = names[value] else { return String(value) }
        return "HKCategoryValue" + prefix + name
    }
}
