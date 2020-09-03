//
// Copyright (c) Vatsal Manot
//

import Swallow

public protocol Lock: ScopedMutex {
    associatedtype AcquireResult
    associatedtype ReleaseResult
    
    @discardableResult
    func acquireOrBlock() -> AcquireResult
    @discardableResult
    func relinquish() -> ReleaseResult
}

public protocol TestableLock: Lock, TestableScopedMutex {
    associatedtype AttemptedAcquireResult
    
    var hasBeenAcquired: Bool { get }
    func acquireOrFail() throws -> AttemptedAcquireResult
}

public protocol ReentrantLock: Lock, ReentrantMutex {
    
}

// MARK: - Implementation -

extension Lock {
    @discardableResult
    @inlinable
    public func withCriticalScope<T>(_ f: (() throws -> T)) rethrows -> T {
        defer {
            relinquish()
        }
        acquireOrBlock()
        return try f()
    }
}

extension TestableLock {
    public var hasBeenAcquired: Bool {
        if let _ = try? acquireOrFail() {
            relinquish()
            return false
        } else {
            return true
        }
    }
    
    @discardableResult
    public func withCriticalScope<T>(attempt f: (() throws -> T)) rethrows -> T? {
        guard let _ = try? acquireOrFail() else {
            return nil
        }
        defer {
            relinquish()
        }
        return try f()
    }
}
