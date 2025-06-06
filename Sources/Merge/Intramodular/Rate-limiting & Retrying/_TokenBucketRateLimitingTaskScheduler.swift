//
// Copyright (c) Vatsal Manot
//

import Combine
import Dispatch
import Foundation
import Swallow

/// Controls the rate at which the work is executed. Uses the classic [token
/// bucket](https://en.wikipedia.org/wiki/Token_bucket) algorithm.
///
/// The main use case for rate limiter is to support large (infinite) collections
/// of images by preventing trashing of underlying systems, primary URLSession.
///
/// The implementation supports quick bursts of requests which can be executed
/// without any delays when "the bucket is full". This is important to prevent
/// rate limiter from affecting "normal" requests flow.
public actor _TokenBucketRateLimitingTaskScheduler: Sendable {
    // This type isn't really Sendable and requires the caller to use the same
    // queue as it does for synchronization.
    
    private let bucket: TokenBucket
    private let pending = _NaiveDoublyLinkedList<Work>() // fast append, fast remove first
    private var isExecutingPendingTasks = false
    
    typealias Work = () -> Bool
    
    /// Initializes the `RateLimiter` with the given configuration.
    /// - parameters:
    ///   - queue: Queue on which to execute pending tasks.
    ///   - rate: Maximum number of requests per second. 80 by default.
    ///   - burst: Maximum number of requests which can be executed without any
    ///   delays when "bucket is full". 25 by default.
    init(
        rate: Int = 80,
        burst: Int = 25
    ) {
        self.bucket = TokenBucket(rate: Double(rate), burst: Double(burst))
    }
    
    /// - parameter closure: Returns `true` if the close was executed, `false`
    /// if the work was cancelled.
    func schedule( _ work: @escaping Work) async {
        if !pending.isEmpty || !bucket.execute(work) {
            pending.append(work)
            
            await setNeedsExecutePendingTasks()
        }
    }
    
    private func setNeedsExecutePendingTasks() async {
        guard !isExecutingPendingTasks else {
            return
        }
        
        isExecutingPendingTasks = true
        
        // Compute a delay such that by the time the closure is executed the
        // bucket is refilled to a point that is able to execute at least one
        // pending task. With a rate of 80 tasks we expect a refill every ~26 ms
        // or as soon as the new tasks are added.
        let bucketRate = 1000.0 / bucket.rate
        let delay = Int(2.1 * bucketRate) // 14 ms for rate 80 (default)
        let bounds = min(100, max(15, delay))
        
        do {
            try await Task.sleep(.milliseconds(bounds))
        } catch {
            runtimeIssue(error)
        }
        
        await self.executePendingTasks()
    }
    
    private func executePendingTasks() async {
        while let node = pending.first, bucket.execute(node.value) {
            pending.remove(node)
        }
        
        isExecutingPendingTasks = false
        
        if !pending.isEmpty { // Not all pending items were executed
            await setNeedsExecutePendingTasks()
        }
    }
}

extension _TokenBucketRateLimitingTaskScheduler: _AsyncTaskScheduler {
    public nonisolated func schedule(
        _ task: @escaping () async -> Void
    ) {
        Task {
            await schedule {
                Task {
                    await task()
                }
                
                return true
            }
        }
    }
}

private final class TokenBucket {
    let rate: Double
    private let burst: Double // maximum bucket size
    private var bucket: Double
    private var timestamp: TimeInterval // last refill timestamp
    
    /// - parameter rate: Rate (tokens/second) at which bucket is refilled.
    /// - parameter burst: Bucket size (maximum number of tokens).
    init(rate: Double, burst: Double) {
        self.rate = rate
        self.burst = burst
        self.bucket = burst
        self.timestamp = CFAbsoluteTimeGetCurrent()
    }
    
    /// Returns `true` if the closure was executed, `false` if dropped.
    func execute(_ work: () -> Bool) -> Bool {
        refill()
        
        guard bucket >= 1.0 else {
            return false // bucket is empty
        }
        
        if work() {
            bucket -= 1.0 // work was cancelled, no need to reduce the bucket
        }
        
        return true
    }
    
    private func refill() {
        let now = CFAbsoluteTimeGetCurrent()
        bucket += rate * max(0, now - timestamp) // rate * (time delta)
        timestamp = now
        if bucket > burst { // prevent bucket overflow
            bucket = burst
        }
    }
}
