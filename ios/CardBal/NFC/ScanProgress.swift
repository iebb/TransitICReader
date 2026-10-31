import Foundation

/// One reading step, shown as the second line of the iPhone scan sheet and
/// mirrored into the in-app reader status.
enum ScanStep: Equatable {
    case found, balance, transactions, transactionCount(Int, Int), activity, details
    case octopusOnline, octopusUnavailable, finishing, done

    var message: String {
        switch self {
        case .found: return String(localized: "Card found. Reading…")
        case .balance: return String(localized: "Reading balance…")
        case .transactions: return String(localized: "Reading transactions…")
        case .transactionCount(let number, let total): return String(localized: "Reading transactions (\(number) of \(total))…")
        case .activity: return String(localized: "Reading transit activity…")
        case .details: return String(localized: "Reading card details…")
        case .octopusOnline: return String(localized: "Checking Octopus online… Keep the card in place.")
        case .octopusUnavailable: return String(localized: "Octopus Online is unavailable. Finishing the read…")
        case .finishing: return String(localized: "Almost done…")
        case .done: return String(localized: "Card read.")
        }
    }

    /// Counter updates belong to the same step as the plain line.
    fileprivate var family: ScanStep {
        if case .transactionCount = self { return .transactions }
        return self
    }

    /// Detection and the end of the slow online check are shown at once;
    /// other steps must last a moment before they replace the current line.
    fileprivate var isImmediate: Bool { self == .found || self == .octopusUnavailable || self == .done }
}

/// Progress channel for decoders. A reader binds one for each scan with
/// `ScanProgress.$current.withValue(_:operation:)`; elsewhere (tests, backup
/// replay) `report` does nothing.
///
/// Steps are coalesced: a reported step replaces the current line only after
/// `delay` unless a later report supersedes it first, so steps shorter than
/// the delay never flash. Counter updates of a pending step keep its timer,
/// which throttles them instead of postponing them indefinitely.
final class ScanProgress: @unchecked Sendable {
    @TaskLocal static var current: ScanProgress?

    static func report(_ step: ScanStep) { current?.report(step) }

    private let lock = NSLock()
    private let delay: UInt64
    private let apply: @MainActor (String) -> Void
    private var shown: ScanStep?
    private var pending: ScanStep?
    private var pendingToken = 0
    private var delivery = 0
    private var isFinished = false

    init(delayNanoseconds: UInt64 = 300_000_000, apply: @escaping @MainActor (String) -> Void) {
        delay = delayNanoseconds
        self.apply = apply
    }

    func report(_ step: ScanStep) {
        lock.lock(); defer { lock.unlock() }
        guard !isFinished else { return }
        // The unavailable line already says the read is finishing.
        if step == .finishing, shown == .octopusUnavailable || pending == .octopusUnavailable { return }
        if step == pending || (pending == nil && step == shown) { return }
        if step.isImmediate {
            cancelPending()
            deliver(step)
        } else if step == shown {
            // Back to the line already shown before the pending one appeared.
            cancelPending()
        } else if let pending, pending.family == step.family {
            self.pending = step
        } else {
            cancelPending()
            pending = step
            let token = pendingToken
            let delay = delay
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                self?.firePending(token)
            }
        }
    }

    /// Drops pending and queued lines so a final or error message stays.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        isFinished = true
        cancelPending()
    }

    private func firePending(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !isFinished, token == pendingToken, let pending else { return }
        cancelPending()
        deliver(pending)
    }

    /// Caller holds the lock.
    private func cancelPending() {
        pending = nil
        pendingToken += 1
    }

    /// Caller holds the lock.
    private func deliver(_ step: ScanStep) {
        shown = step
        delivery += 1
        let number = delivery
        let message = step.message
        Task { @MainActor [weak self] in
            guard let self, self.isLatest(number) else { return }
            self.apply(message)
        }
    }

    private func isLatest(_ number: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !isFinished && number == delivery
    }
}
