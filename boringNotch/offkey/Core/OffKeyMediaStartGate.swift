struct OffKeyMediaStartGate: Equatable {
    typealias Generation = UInt64

    private(set) var generation: Generation = 0
    private(set) var mediaDesired = false

    mutating func requestStart(desired: Bool) -> Generation? {
        advanceGeneration()
        mediaDesired = desired
        return desired ? generation : nil
    }

    mutating func updateDesired(_ desired: Bool) {
        advanceGeneration()
        mediaDesired = desired
    }

    func permitsInstallation(
        generation candidate: Generation,
        mode: OffKeyTapMode
    ) -> Bool {
        candidate == generation
            && mediaDesired
            && mode == .mediaKeys
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }
}
