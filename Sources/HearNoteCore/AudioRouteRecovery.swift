import Foundation

/// A meeting session survives hardware replacement. Input leases and recovery
/// operations are separate so late callbacks cannot resume a stopped session.
public struct AudioRouteRecovery {
    public let maximumAttempts: Int
    public private(set) var inputID: UUID?
    public private(set) var recoveryID: UUID?
    public private(set) var attempts = 0
    public private(set) var isActive = false

    public init(maximumAttempts: Int = 6) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    @discardableResult
    public mutating func start() -> UUID {
        let input = UUID()
        isActive = true
        inputID = input
        recoveryID = nil
        attempts = 0
        return input
    }

    /// Further changes during an attempt reuse its bounded recovery operation.
    public mutating func configurationChanged(input: UUID) -> UUID? {
        guard isActive, inputID == input else { return nil }
        inputID = nil
        if let recoveryID { return recoveryID }
        let recovery = UUID()
        recoveryID = recovery
        attempts = 0
        return recovery
    }

    public mutating func nextAttempt(recovery: UUID) -> UUID? {
        guard isActive, recoveryID == recovery, inputID == nil,
              attempts < maximumAttempts else { return nil }
        attempts += 1
        let input = UUID()
        inputID = input
        return input
    }

    public mutating func attemptFailed(recovery: UUID, input: UUID) {
        guard isActive, recoveryID == recovery, inputID == input else { return }
        inputID = nil
    }

    public mutating func succeeded(recovery: UUID, input: UUID, activeHardwareInput: UUID?) -> Bool {
        guard isActive, recoveryID == recovery, inputID == input,
              activeHardwareInput == input else { return false }
        recoveryID = nil
        attempts = 0
        return true
    }

    public func accepts(input: UUID) -> Bool { isActive && inputID == input }

    public mutating func stop() {
        isActive = false
        inputID = nil
        recoveryID = nil
        attempts = 0
    }
}
