import Foundation

enum LineRetractionDelay: Double, CaseIterable, Identifiable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60
    case never = 0

    static let preferenceKey = "lineRetractionDelay.v1"
    var id: Double { rawValue }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let seconds = defaults.object(forKey: preferenceKey) as? NSNumber,
              let delay = Self(rawValue: seconds.doubleValue) else { return .fiveSeconds }
        return delay
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    func shouldRetract(after seconds: TimeInterval) -> Bool {
        self != .never && seconds >= rawValue
    }
}
