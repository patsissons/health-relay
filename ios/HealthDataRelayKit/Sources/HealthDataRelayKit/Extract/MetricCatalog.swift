import Foundation

/// A kind of value a unit can be swapped within.
public enum UnitDimension: String, Codable, Sendable, CaseIterable {
    case energy, distance, shortLength, mass, temperature, volume, speed, time, none

    /// The units a user can pick, as HKUnit strings; the first is the default.
    public var choices: [String] {
        switch self {
        case .energy: ["kcal", "kJ"]
        case .distance: ["km", "mi", "m"]
        case .shortLength: ["cm", "in", "m"]
        case .mass: ["kg", "lb"]
        case .temperature: ["degC", "degF"]
        case .volume: ["mL", "fl_oz_us", "L"]
        case .speed: ["km/hr", "mi/hr", "m/s"]
        case .time: ["min", "hr", "s"]
        case .none: []
        }
    }
}

/// A health metric a pipeline can extract, by the name templates use. This
/// is the wider list beside `Catalog`, which stays frozen for the native
/// push: adding a metric here can't change what an existing receiver gets.
public struct Metric: Sendable, Hashable, Identifiable {
    /// How a metric's values combine into one point.
    public enum Form: String, Sendable {
        /// Cumulative: the bucket's sum, `qty`.
        case total
        /// Discrete: the bucket's mean, `qty`.
        case average
        /// `Min`, `Avg` and `Max`.
        case range
        /// `systolic` and `diastolic`, paired by reading.
        case bloodPressure
        /// Nights, built from sleep stages.
        case sleep
        /// A category type counted per bucket, `qty`.
        case eventCount
        /// A category type's total duration in minutes, `qty`.
        case eventMinutes
    }

    public enum Group: String, Sendable, CaseIterable {
        case activity, mobility, heart, respiratory, body, hearing, sleep, nutrition, medical, other
    }

    public let name: String
    public let title: String
    public let group: Group
    public let form: Form
    /// HealthKit identifiers it reads. Only blood pressure has two.
    public let identifiers: [String]
    /// The HKUnit string it reads in by default.
    public let unit: String
    /// The text written for that unit, when it differs from `unit`.
    public let label: String
    public let dimension: UnitDimension

    public var id: String { name }

    /// True for a type HealthKit reads as a category.
    public var isCategory: Bool {
        switch form {
        case .sleep, .eventCount, .eventMinutes: true
        default: false
        }
    }

    public var healthTypes: [HealthType] {
        identifiers.map { HealthType(isCategory ? .category : .quantity, $0) }
    }

    init(_ name: String, _ title: String, _ group: Group, _ form: Form, _ id: String, _ unit: String, label: String? = nil, dimension: UnitDimension = .none) {
        self.name = name
        self.title = title
        self.group = group
        self.form = form
        let prefix = form == .sleep || form == .eventCount || form == .eventMinutes ? "HKCategoryTypeIdentifier" : "HKQuantityTypeIdentifier"
        identifiers = id.split(separator: ",").map { prefix + $0 }
        self.unit = unit
        self.label = label ?? unit
        self.dimension = dimension
    }
}

/// Every metric, every symptom and every event type a pipeline can extract.
/// A type the running iOS lacks is skipped at read time.
public enum MetricCatalog {
    public static let metrics: [Metric] = activity + mobility + heart + respiratory + body + hearing + sleep + nutrition + medical

    public static func metric(named name: String) -> Metric? { byName[name] }

    private static let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0) })

    private static func t(_ n: String, _ title: String, _ g: Metric.Group, _ id: String, _ u: String, _ d: UnitDimension = .none) -> Metric {
        Metric(n, title, g, .total, id, u, dimension: d)
    }

    private static func a(_ n: String, _ title: String, _ g: Metric.Group, _ id: String, _ u: String, _ d: UnitDimension = .none, label: String? = nil) -> Metric {
        Metric(n, title, g, .average, id, u, label: label, dimension: d)
    }

    static let activity: [Metric] = [
        t("step_count", "Steps", .activity, "StepCount", "count"),
        t("walking_running_distance", "Walking + Running Distance", .activity, "DistanceWalkingRunning", "km", .distance),
        t("cycling_distance", "Cycling Distance", .activity, "DistanceCycling", "km", .distance),
        t("swimming_distance", "Swimming Distance", .activity, "DistanceSwimming", "m", .distance),
        t("wheelchair_distance", "Wheelchair Distance", .activity, "DistanceWheelchair", "km", .distance),
        t("downhill_snow_sports_distance", "Downhill Snow Sports Distance", .activity, "DistanceDownhillSnowSports", "km", .distance),
        t("rowing_distance", "Rowing Distance", .activity, "DistanceRowing", "km", .distance),
        t("paddle_sports_distance", "Paddle Sports Distance", .activity, "DistancePaddleSports", "km", .distance),
        t("cross_country_skiing_distance", "Cross Country Skiing Distance", .activity, "DistanceCrossCountrySkiing", "km", .distance),
        t("skating_sports_distance", "Skating Sports Distance", .activity, "DistanceSkatingSports", "km", .distance),
        t("active_energy", "Active Energy", .activity, "ActiveEnergyBurned", "kcal", .energy),
        t("basal_energy_burned", "Resting Energy", .activity, "BasalEnergyBurned", "kcal", .energy),
        t("apple_exercise_time", "Exercise Minutes", .activity, "AppleExerciseTime", "min", .time),
        t("apple_move_time", "Move Minutes", .activity, "AppleMoveTime", "min", .time),
        t("apple_stand_time", "Stand Minutes", .activity, "AppleStandTime", "min", .time),
        Metric("apple_stand_hour", "Stand Hours", .activity, .eventCount, "AppleStandHour", "count"),
        t("flights_climbed", "Flights Climbed", .activity, "FlightsClimbed", "count"),
        t("push_count", "Wheelchair Pushes", .activity, "PushCount", "count"),
        t("swimming_stroke_count", "Swimming Strokes", .activity, "SwimmingStrokeCount", "count"),
        t("nike_fuel", "NikeFuel", .activity, "NikeFuel", "count"),
        t("time_in_daylight", "Time in Daylight", .activity, "TimeInDaylight", "min", .time),
        t("number_of_times_fallen", "Number of Times Fallen", .activity, "NumberOfTimesFallen", "count"),
        a("physical_effort", "Physical Effort", .activity, "PhysicalEffort", "kcal/(kg*hr)", label: "kcal/hr·kg"),
        a("workout_effort_score", "Workout Effort", .activity, "WorkoutEffortScore", "appleEffortScore"),
        a("estimated_workout_effort_score", "Estimated Workout Effort", .activity, "EstimatedWorkoutEffortScore", "appleEffortScore"),
        a("cycling_cadence", "Cycling Cadence", .activity, "CyclingCadence", "count/min"),
        a("cycling_functional_threshold_power", "Cycling Functional Threshold Power", .activity, "CyclingFunctionalThresholdPower", "W"),
        a("cycling_power", "Cycling Power", .activity, "CyclingPower", "W"),
        a("cycling_speed", "Cycling Speed", .activity, "CyclingSpeed", "km/hr", .speed),
        a("running_power", "Running Power", .activity, "RunningPower", "W"),
        a("running_speed", "Running Speed", .activity, "RunningSpeed", "km/hr", .speed),
        a("running_ground_contact_time", "Ground Contact Time", .activity, "RunningGroundContactTime", "ms"),
        a("running_stride_length", "Stride Length", .activity, "RunningStrideLength", "m", .shortLength),
        a("running_vertical_oscillation", "Vertical Oscillation", .activity, "RunningVerticalOscillation", "cm", .shortLength),
        a("rowing_speed", "Rowing Speed", .activity, "RowingSpeed", "km/hr", .speed),
        a("cross_country_skiing_speed", "Cross Country Skiing Speed", .activity, "CrossCountrySkiingSpeed", "km/hr", .speed),
        a("paddle_sports_speed", "Paddle Sports Speed", .activity, "PaddleSportsSpeed", "km/hr", .speed),
        a("underwater_depth", "Underwater Depth", .activity, "UnderwaterDepth", "m", .shortLength),
        a("water_temperature", "Water Temperature", .activity, "WaterTemperature", "degC", .temperature),
    ]

    static let mobility: [Metric] = [
        a("walking_speed", "Walking Speed", .mobility, "WalkingSpeed", "km/hr", .speed),
        a("walking_step_length", "Walking Step Length", .mobility, "WalkingStepLength", "cm", .shortLength),
        a("walking_asymmetry_percentage", "Walking Asymmetry", .mobility, "WalkingAsymmetryPercentage", "%"),
        a("walking_double_support_percentage", "Walking Double Support", .mobility, "WalkingDoubleSupportPercentage", "%"),
        a("apple_walking_steadiness", "Walking Steadiness", .mobility, "AppleWalkingSteadiness", "%"),
        a("stair_speed_up", "Stair Speed Up", .mobility, "StairAscentSpeed", "m/s", .speed),
        a("stair_speed_down", "Stair Speed Down", .mobility, "StairDescentSpeed", "m/s", .speed),
        a("six_minute_walking_test_distance", "Six-Minute Walk", .mobility, "SixMinuteWalkTestDistance", "m", .distance),
    ]

    static let heart: [Metric] = [
        Metric("heart_rate", "Heart Rate", .heart, .range, "HeartRate", "count/min"),
        a("resting_heart_rate", "Resting Heart Rate", .heart, "RestingHeartRate", "count/min"),
        a("walking_heart_rate_average", "Walking Heart Rate", .heart, "WalkingHeartRateAverage", "count/min"),
        a("heart_rate_variability", "Heart Rate Variability", .heart, "HeartRateVariabilitySDNN", "ms"),
        a("heart_rate_variability_rmssd", "Heart Rate Variability (RMSSD)", .heart, "HeartRateVariabilityRMSSD", "ms"),
        a("cardio_recovery", "Cardio Recovery", .heart, "HeartRateRecoveryOneMinute", "count/min"),
        a("vo2_max", "VO2 Max", .heart, "VO2Max", "ml/(kg*min)", label: "ml/(kg·min)"),
        a("atrial_fibrillation_burden", "AFib Burden", .heart, "AtrialFibrillationBurden", "%"),
        a("peripheral_perfusion_index", "Perfusion Index", .heart, "PeripheralPerfusionIndex", "%"),
    ]

    static let respiratory: [Metric] = [
        a("respiratory_rate", "Respiratory Rate", .respiratory, "RespiratoryRate", "count/min"),
        a("blood_oxygen_saturation", "Blood Oxygen", .respiratory, "OxygenSaturation", "%"),
        a("forced_expiratory_volume_1", "Forced Expiratory Volume", .respiratory, "ForcedExpiratoryVolume1", "L"),
        a("forced_vital_capacity", "Forced Vital Capacity", .respiratory, "ForcedVitalCapacity", "L"),
        a("peak_expiratory_flow_rate", "Peak Expiratory Flow", .respiratory, "PeakExpiratoryFlowRate", "L/min"),
        t("inhaler_usage", "Inhaler Usage", .respiratory, "InhalerUsage", "count"),
    ]

    static let body: [Metric] = [
        a("weight_body_mass", "Weight", .body, "BodyMass", "kg", .mass),
        a("height", "Height", .body, "Height", "m", .shortLength),
        a("body_mass_index", "Body Mass Index", .body, "BodyMassIndex", "count"),
        a("body_fat_percentage", "Body Fat", .body, "BodyFatPercentage", "%"),
        a("lean_body_mass", "Lean Body Mass", .body, "LeanBodyMass", "kg", .mass),
        a("waist_circumference", "Waist Circumference", .body, "WaistCircumference", "cm", .shortLength),
        a("body_temperature", "Body Temperature", .body, "BodyTemperature", "degC", .temperature),
        a("basal_body_temperature", "Basal Body Temperature", .body, "BasalBodyTemperature", "degC", .temperature),
        a("apple_sleeping_wrist_temperature", "Sleeping Wrist Temperature", .body, "AppleSleepingWristTemperature", "degC", .temperature),
        a("electrodermal_activity", "Electrodermal Activity", .body, "ElectrodermalActivity", "mcS"),
    ]

    static let hearing: [Metric] = [
        a("environmental_audio_exposure", "Environmental Sound Levels", .hearing, "EnvironmentalAudioExposure", "dBASPL"),
        a("headphone_audio_exposure", "Headphone Audio Levels", .hearing, "HeadphoneAudioExposure", "dBASPL"),
        a("environmental_sound_reduction", "Environmental Sound Reduction", .hearing, "EnvironmentalSoundReduction", "dBASPL"),
    ]

    static let sleep: [Metric] = [
        Metric("sleep_analysis", "Sleep", .sleep, .sleep, "SleepAnalysis", "hr", dimension: .none),
        a("breathing_disturbances", "Breathing Disturbances", .sleep, "AppleSleepingBreathingDisturbances", "count"),
    ]

    static let medical: [Metric] = [
        Metric("blood_pressure", "Blood Pressure", .medical, .bloodPressure, "BloodPressureSystolic,BloodPressureDiastolic", "mmHg"),
        a("blood_glucose", "Blood Glucose", .medical, "BloodGlucose", "mg/dL"),
        t("insulin_delivery", "Insulin Delivery", .medical, "InsulinDelivery", "IU"),
        a("blood_alcohol_content", "Blood Alcohol Content", .medical, "BloodAlcoholContent", "%"),
        t("number_of_alcoholic_beverages", "Alcoholic Beverages", .medical, "NumberOfAlcoholicBeverages", "count"),
        a("uv_exposure", "UV Exposure", .medical, "UVExposure", "count"),
        Metric("mindful_minutes", "Mindful Minutes", .other, .eventMinutes, "MindfulSession", "min", dimension: .none),
        Metric("handwashing", "Handwashing", .other, .eventCount, "HandwashingEvent", "count"),
        Metric("toothbrushing", "Toothbrushing", .other, .eventCount, "ToothbrushingEvent", "count"),
    ]

    static let nutrition: [Metric] = [
        t("dietary_energy", "Dietary Energy", .nutrition, "DietaryEnergyConsumed", "kcal", .energy),
        t("protein", "Protein", .nutrition, "DietaryProtein", "g"),
        t("carbohydrates", "Carbohydrates", .nutrition, "DietaryCarbohydrates", "g"),
        t("total_fat", "Total Fat", .nutrition, "DietaryFatTotal", "g"),
        t("saturated_fat", "Saturated Fat", .nutrition, "DietaryFatSaturated", "g"),
        t("monounsaturated_fat", "Monounsaturated Fat", .nutrition, "DietaryFatMonounsaturated", "g"),
        t("polyunsaturated_fat", "Polyunsaturated Fat", .nutrition, "DietaryFatPolyunsaturated", "g"),
        t("cholesterol", "Cholesterol", .nutrition, "DietaryCholesterol", "mg"),
        t("sodium", "Sodium", .nutrition, "DietarySodium", "mg"),
        t("fiber", "Fiber", .nutrition, "DietaryFiber", "g"),
        t("dietary_sugar", "Sugar", .nutrition, "DietarySugar", "g"),
        t("caffeine", "Caffeine", .nutrition, "DietaryCaffeine", "mg"),
        t("dietary_water", "Water", .nutrition, "DietaryWater", "mL", .volume),
        t("vitamin_a", "Vitamin A", .nutrition, "DietaryVitaminA", "mcg"),
        t("vitamin_b6", "Vitamin B6", .nutrition, "DietaryVitaminB6", "mg"),
        t("vitamin_b12", "Vitamin B12", .nutrition, "DietaryVitaminB12", "mcg"),
        t("vitamin_c", "Vitamin C", .nutrition, "DietaryVitaminC", "mg"),
        t("vitamin_d", "Vitamin D", .nutrition, "DietaryVitaminD", "mcg"),
        t("vitamin_e", "Vitamin E", .nutrition, "DietaryVitaminE", "mg"),
        t("vitamin_k", "Vitamin K", .nutrition, "DietaryVitaminK", "mcg"),
        t("thiamin", "Thiamin", .nutrition, "DietaryThiamin", "mg"),
        t("riboflavin", "Riboflavin", .nutrition, "DietaryRiboflavin", "mg"),
        t("niacin", "Niacin", .nutrition, "DietaryNiacin", "mg"),
        t("pantothenic_acid", "Pantothenic Acid", .nutrition, "DietaryPantothenicAcid", "mg"),
        t("folate", "Folate", .nutrition, "DietaryFolate", "mcg"),
        t("biotin", "Biotin", .nutrition, "DietaryBiotin", "mcg"),
        t("calcium", "Calcium", .nutrition, "DietaryCalcium", "mg"),
        t("iron", "Iron", .nutrition, "DietaryIron", "mg"),
        t("magnesium", "Magnesium", .nutrition, "DietaryMagnesium", "mg"),
        t("phosphorus", "Phosphorus", .nutrition, "DietaryPhosphorus", "mg"),
        t("potassium", "Potassium", .nutrition, "DietaryPotassium", "mg"),
        t("zinc", "Zinc", .nutrition, "DietaryZinc", "mg"),
        t("copper", "Copper", .nutrition, "DietaryCopper", "mg"),
        t("manganese", "Manganese", .nutrition, "DietaryManganese", "mg"),
        t("selenium", "Selenium", .nutrition, "DietarySelenium", "mcg"),
        t("chloride", "Chloride", .nutrition, "DietaryChloride", "mg"),
        t("chromium", "Chromium", .nutrition, "DietaryChromium", "mcg"),
        t("iodine", "Iodine", .nutrition, "DietaryIodine", "mcg"),
        t("molybdenum", "Molybdenum", .nutrition, "DietaryMolybdenum", "mcg"),
    ]

    // MARK: Event types

    /// A category type read event by event.
    public struct EventType: Sendable, Hashable {
        public let id: String
        public let name: String
        /// The values' names by raw value; empty for a type with no value.
        public let values: [Int: String]

        init(_ bare: String, _ name: String, _ values: [Int: String] = [:]) {
            id = "HKCategoryTypeIdentifier" + bare
            self.name = name
            self.values = values
        }

        public var type: HealthType { HealthType(.category, id) }

        public func valueName(_ raw: Int) -> String? {
            values.isEmpty ? nil : values[raw] ?? String(raw)
        }
    }

    private static let severity = [0: "Unspecified", 1: "Not Present", 2: "Mild", 3: "Moderate", 4: "Severe"]
    private static let presence = [0: "Present", 1: "Not Present"]
    private static let testResult = [1: "Negative", 2: "Positive", 3: "Indeterminate"]

    public static let symptoms: [EventType] = [
        ("AbdominalCramps", "Abdominal Cramps"), ("Acne", "Acne"), ("BladderIncontinence", "Bladder Incontinence"),
        ("Bloating", "Bloating"), ("BreastPain", "Breast Pain"), ("ChestTightnessOrPain", "Chest Tightness or Pain"),
        ("Chills", "Chills"), ("Constipation", "Constipation"), ("Coughing", "Coughing"), ("Diarrhea", "Diarrhea"),
        ("Dizziness", "Dizziness"), ("DrySkin", "Dry Skin"), ("Fainting", "Fainting"), ("Fatigue", "Fatigue"), ("Fever", "Fever"),
        ("GeneralizedBodyAche", "Generalized Body Ache"), ("HairLoss", "Hair Loss"), ("Headache", "Headache"),
        ("Heartburn", "Heartburn"), ("HotFlashes", "Hot Flashes"), ("LossOfSmell", "Loss of Smell"), ("LossOfTaste", "Loss of Taste"),
        ("LowerBackPain", "Lower Back Pain"), ("MemoryLapse", "Memory Lapse"), ("Nausea", "Nausea"), ("NightSweats", "Night Sweats"),
        ("PelvicPain", "Pelvic Pain"), ("RapidPoundingOrFlutteringHeartbeat", "Rapid, Pounding or Fluttering Heartbeat"),
        ("RunnyNose", "Runny Nose"), ("ShortnessOfBreath", "Shortness of Breath"), ("SinusCongestion", "Sinus Congestion"),
        ("SkippedHeartbeat", "Skipped Heartbeat"), ("SoreThroat", "Sore Throat"), ("VaginalDryness", "Vaginal Dryness"),
        ("Vomiting", "Vomiting"), ("Wheezing", "Wheezing"),
    ].map { EventType($0.0, $0.1, severity) } + [
        EventType("MoodChanges", "Mood Changes", presence),
        EventType("SleepChanges", "Sleep Changes", presence),
        EventType("AppetiteChanges", "Appetite Changes", [0: "Unspecified", 1: "No Change", 2: "Decreased", 3: "Increased"]),
    ]

    public static let cycleTracking: [EventType] = [
        EventType("MenstrualFlow", "Menstrual Flow", [1: "Unspecified", 2: "Light", 3: "Medium", 4: "Heavy", 5: "None"]),
        EventType("IntermenstrualBleeding", "Spotting"),
        EventType("InfrequentMenstrualCycles", "Infrequent Periods"),
        EventType("IrregularMenstrualCycles", "Irregular Cycles"),
        EventType("PersistentIntermenstrualBleeding", "Persistent Spotting"),
        EventType("ProlongedMenstrualPeriods", "Prolonged Periods"),
        EventType("CervicalMucusQuality", "Cervical Mucus Quality", [1: "Dry", 2: "Sticky", 3: "Creamy", 4: "Watery", 5: "Egg White"]),
        EventType("OvulationTestResult", "Ovulation Test Result", [1: "Negative", 2: "Luteinizing Hormone Surge", 3: "Indeterminate", 4: "Estrogen Surge"]),
        EventType("PregnancyTestResult", "Pregnancy Test Result", testResult),
        EventType("ProgesteroneTestResult", "Progesterone Test Result", testResult),
        EventType("SexualActivity", "Sexual Activity"),
        EventType("Contraceptive", "Contraceptive", [1: "Unspecified", 2: "Implant", 3: "Injection", 4: "Intrauterine Device", 5: "Intravaginal Ring", 6: "Oral", 7: "Patch"]),
        EventType("Lactation", "Lactation"),
        EventType("Pregnancy", "Pregnancy"),
        EventType("BleedingAfterPregnancy", "Bleeding After Pregnancy", [1: "Unspecified", 2: "Light", 3: "Medium", 4: "Heavy", 5: "None"]),
        EventType("BleedingDuringPregnancy", "Bleeding During Pregnancy", [1: "Unspecified", 2: "Light", 3: "Medium", 4: "Heavy", 5: "None"]),
    ]

    public static let notifications: [EventType] = [
        EventType("HighHeartRateEvent", "High Heart Rate"),
        EventType("LowHeartRateEvent", "Low Heart Rate"),
        EventType("IrregularHeartRhythmEvent", "Irregular Heart Rhythm"),
        EventType("LowCardioFitnessEvent", "Low Cardio Fitness", [1: "Low Fitness"]),
        EventType("HypertensionEvent", "Hypertension"),
        EventType("SleepApneaEvent", "Sleep Apnea", [0: "Unspecified", 1: "Not Present", 2: "Mild", 3: "Moderate", 4: "Severe"]),
        EventType("AudioExposureEvent", "Loud Environment", [1: "Loud Environment"]),
        EventType("HeadphoneAudioExposureEvent", "Headphone Limit", [1: "Seven-Day Limit"]),
        EventType("AppleWalkingSteadinessEvent", "Walking Steadiness", [1: "Initial Low", 2: "Initial Very Low", 3: "Repeat Low", 4: "Repeat Very Low"]),
    ]

    // MARK: Sleep

    /// `HKCategoryValueSleepAnalysis`'s raw values.
    public enum SleepStage: Int, Sendable, CaseIterable {
        case inBed = 0, asleep = 1, awake = 2, core = 3, deep = 4, rem = 5

        public var name: String {
            switch self {
            case .inBed: "In Bed"
            case .asleep: "Asleep"
            case .awake: "Awake"
            case .core: "Core"
            case .deep: "Deep"
            case .rem: "REM"
            }
        }
    }

    /// Workout statistics a workout can carry, read by identifier.
    public static let workoutStatistics: [(name: String, id: String, unit: String)] = [
        ("activeEnergy", "HKQuantityTypeIdentifierActiveEnergyBurned", "kcal"),
        ("basalEnergy", "HKQuantityTypeIdentifierBasalEnergyBurned", "kcal"),
        ("heartRate", "HKQuantityTypeIdentifierHeartRate", "count/min"),
        ("stepCount", "HKQuantityTypeIdentifierStepCount", "count"),
        ("flightsClimbed", "HKQuantityTypeIdentifierFlightsClimbed", "count"),
        ("walkingAndRunningDistance", "HKQuantityTypeIdentifierDistanceWalkingRunning", "km"),
        ("cyclingDistance", "HKQuantityTypeIdentifierDistanceCycling", "km"),
        ("swimmingDistance", "HKQuantityTypeIdentifierDistanceSwimming", "m"),
        ("swimmingStrokeCount", "HKQuantityTypeIdentifierSwimmingStrokeCount", "count"),
        ("wheelchairDistance", "HKQuantityTypeIdentifierDistanceWheelchair", "km"),
        ("pushCount", "HKQuantityTypeIdentifierPushCount", "count"),
        ("downhillSnowSportsDistance", "HKQuantityTypeIdentifierDistanceDownhillSnowSports", "km"),
        ("rowingDistance", "HKQuantityTypeIdentifierDistanceRowing", "km"),
        ("paddleSportsDistance", "HKQuantityTypeIdentifierDistancePaddleSports", "km"),
        ("crossCountrySkiingDistance", "HKQuantityTypeIdentifierDistanceCrossCountrySkiing", "km"),
        ("skatingSportsDistance", "HKQuantityTypeIdentifierDistanceSkatingSports", "km"),
        ("runningPower", "HKQuantityTypeIdentifierRunningPower", "W"),
        ("runningSpeed", "HKQuantityTypeIdentifierRunningSpeed", "km/hr"),
        ("runningGroundContactTime", "HKQuantityTypeIdentifierRunningGroundContactTime", "ms"),
        ("runningStrideLength", "HKQuantityTypeIdentifierRunningStrideLength", "m"),
        ("runningVerticalOscillation", "HKQuantityTypeIdentifierRunningVerticalOscillation", "cm"),
        ("cyclingPower", "HKQuantityTypeIdentifierCyclingPower", "W"),
        ("cyclingSpeed", "HKQuantityTypeIdentifierCyclingSpeed", "km/hr"),
        ("cyclingCadence", "HKQuantityTypeIdentifierCyclingCadence", "count/min"),
    ]

    /// Every type a pipeline might read: what the app asks for once a
    /// pipeline needs more than the native push's list.
    public static var allTypes: [HealthType] {
        var seen = Set<HealthType>()
        let all = metrics.flatMap(\.healthTypes) + (symptoms + cycleTracking + notifications).map(\.type) + [.workout, .ecg]
        return all.filter { seen.insert($0).inserted }
    }
}
