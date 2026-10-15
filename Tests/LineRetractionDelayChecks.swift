import Foundation

@main
struct LineRetractionDelayChecks {
    static func main() {
        let suite = "local.clipline.retraction-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(LineRetractionDelay.load(from: defaults) == .fiveSeconds)
        for delay in LineRetractionDelay.allCases {
            delay.save(to: defaults)
            let restored = LineRetractionDelay.load(from: UserDefaults(suiteName: suite)!)
            precondition(restored == delay, "Selection survives recreating preferences")
            if delay == .never {
                precondition(!restored.shouldRetract(after: 86_400))
            } else {
                precondition(!restored.shouldRetract(after: delay.rawValue - 0.01))
                precondition(restored.shouldRetract(after: delay.rawValue))
                precondition(restored.shouldRetract(after: delay.rawValue + 1))
            }
        }
        for invalid in [-1.0, 999.0] {
            defaults.set(invalid, forKey: LineRetractionDelay.preferenceKey)
            precondition(LineRetractionDelay.load(from: defaults) == .fiveSeconds)
        }
        defaults.set("invalid", forKey: LineRetractionDelay.preferenceKey)
        precondition(LineRetractionDelay.load(from: defaults) == .fiveSeconds)
        print("PASS: default delay, all timer boundaries, never retract, persistence and invalid preferences")
    }
}
