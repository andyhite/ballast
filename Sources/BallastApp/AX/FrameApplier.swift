@preconcurrency import ApplicationServices
import BallastCore
import Foundation

/// Mutation path. Owns one serial queue per application, so an app that is
/// slow to answer AX (Electron, Java) only delays its own windows. Receives
/// plain frame requests; never touches engine state; reports results back to
/// the main thread.
final class FrameApplier {
    // @unchecked Sendable: AXUIElement is a thread-safe CF object; everything else is a value.
    struct Request: @unchecked Sendable {
        let window: WindowID
        let pid: pid_t
        let element: AXUIElement
        let target: CGRect
        /// Interpolate from the current frame (active Space only; see design doc §5).
        let animation: (duration: Double, easing: Easing, frameInterval: Double)?
    }

    /// Outcome of one request, delivered on the main thread.
    struct Outcome {
        /// Frame read back after applying; nil when the request was
        /// superseded (`completed == false`) or AX could not read the
        /// window (`completed == true`).
        let actual: CGRect?
        /// False when a newer request superseded this one, before or
        /// mid-animation: it says nothing about the window, its constraints
        /// or whether it can be read. True when the request ran to its end.
        let completed: Bool
    }

    typealias Completion = @MainActor (WindowID, CGRect, Outcome) -> Void

    private var queues: [pid_t: DispatchQueue] = [:]
    private let generations = Generations()

    /// Main thread.
    func apply(_ request: Request, completion: @escaping Completion) {
        let generation = generations.next(request.window)
        let generations = self.generations
        let q = queue(for: request.pid)
        q.async {
            Self.run(request, generation: generation, generations: generations, queue: q) { result in
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(request.window, request.target, result) } }
            }
        }
    }

    /// Runs arbitrary AX work (focus, raise, attribute writes) on the app's worker.
    func perform(pid: pid_t, _ work: @escaping @Sendable () -> Void) {
        queue(for: pid).async(execute: work)
    }


    func forget(pid: pid_t) { queues[pid] = nil }

    /// Called on untrack: makes every outstanding generation for `window`
    /// permanently stale, so no queued or in-flight request can complete for it.
    func forget(window: WindowID) { generations.remove(window) }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "dev.ballast.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    // MARK: Worker side

    /// Entry point. Runs on the app's serial queue. `completion` is invoked exactly
    /// once, from that same queue, whether the request finishes, is superseded, or
    /// the window can't be read.
    private static func run(
        _ r: Request, generation: UInt64, generations: Generations, queue: DispatchQueue,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        // Checked before any AX read: a request already superseded while it
        // waited on the app's serial queue (by a newer apply or
        // `forget(window:)` on untrack) must not pay an AX round-trip — up
        // to the 1s messaging timeout on an unresponsive app — just to have
        // its result discarded.
        guard generations.isCurrent(r.window, generation) else {
            completion(Outcome(actual: nil, completed: false))
            return
        }
        guard let start = AX.frame(r.element) else { completion(Outcome(actual: nil, completed: true)); return }
        if start.approximatelyEquals(r.target, tolerance: 0.5) {
            completion(Outcome(actual: start, completed: true))
            return
        }

        guard let anim = r.animation, anim.duration > 0 else {
            finish(r, current: start, completion: completion)
            return
        }

        let begin = DispatchTime.now().uptimeNanoseconds
        let total = anim.duration * 1_000_000_000
        scheduleFrame(
            r, animation: anim, generation: generation, generations: generations, queue: queue,
            begin: begin, total: total, start: start, current: start, frameIndex: 1.0, completion: completion
        )
    }

    /// Schedules the next animation step via `asyncAfter` on the app's own queue instead
    /// of blocking it with a sleep, so sibling requests and `perform(pid:)` work queued
    /// behind (or ahead of) this one can interleave between frames.
    private static func scheduleFrame(
        _ r: Request, animation anim: (duration: Double, easing: Easing, frameInterval: Double),
        generation: UInt64, generations: Generations, queue: DispatchQueue,
        begin: UInt64, total: Double, start: CGRect, current: CGRect, frameIndex: Double,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        let deadlineNanos = begin + UInt64(min(frameIndex * anim.frameInterval * 1_000_000_000, total))
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = DispatchTime(uptimeNanoseconds: max(deadlineNanos, now))
        queue.asyncAfter(deadline: deadline) {
            // Stale generation check happens before any further AX read.
            guard generations.isCurrent(r.window, generation) else {
                completion(Outcome(actual: nil, completed: false))
                return
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin)
            let t = elapsed / total
            if t >= 1 {
                finish(r, current: current, completion: completion)
                return
            }
            let p = anim.easing.apply(t)
            let step = CGRect(x: (start.minX + (r.target.minX - start.minX) * p).rounded(),
                              y: (start.minY + (r.target.minY - start.minY) * p).rounded(),
                              width: (start.width + (r.target.width - start.width) * p).rounded(),
                              height: (start.height + (r.target.height - start.height) * p).rounded())
            set(r.element, from: current, to: step)
            let nextFrameIndex = (elapsed / (anim.frameInterval * 1_000_000_000)).rounded(.down) + 1
            scheduleFrame(
                r, animation: anim, generation: generation, generations: generations, queue: queue,
                begin: begin, total: total, start: start, current: step, frameIndex: nextFrameIndex,
                completion: completion
            )
        }
    }

    /// Applies the final frame, corrects for a WindowServer position nudge on growth,
    /// and reads back the result. Shared by the no-animation path and the animation's
    /// last frame.
    private static func finish(_ r: Request, current: CGRect, completion: @escaping @Sendable (Outcome) -> Void) {
        set(r.element, from: current, to: r.target)
        var actual = AX.frame(r.element)
        // Growing windows can be pushed back on-screen by the WindowServer
        // before their position lands; fix the origin once.
        if let a = actual, abs(a.minX - r.target.minX) > 1 || abs(a.minY - r.target.minY) > 1 {
            AX.setPosition(r.element, r.target.origin)
            actual = AX.frame(r.element)
        }
        completion(Outcome(actual: actual, completed: true))
    }

    /// A single AX attribute write.
    enum Write: Equatable {
        case size(CGSize)
        case position(CGPoint)
    }

    /// Shrinks each axis to min(old, new) first, moves, then grows to the
    /// target size. Pure-shrink and pure-grow transitions collapse to their
    /// original single-extra-write sequence. Either way the window never
    /// extends past its old frame or its destination mid-transition (so it
    /// can't clip off the display or spill onto a neighbouring one).
    static func writes(from: CGRect, to: CGRect) -> [Write] {
        let interim = CGSize(width: min(from.width, to.width), height: min(from.height, to.height))
        var writes: [Write] = []
        if !interim.equalTo(from.size) { writes.append(.size(interim)) }
        if !from.origin.equalTo(to.origin) { writes.append(.position(to.origin)) }
        if !interim.equalTo(to.size) { writes.append(.size(to.size)) }
        return writes
    }

    private static func set(_ element: AXUIElement, from: CGRect, to: CGRect) {
        for write in writes(from: from, to: to) {
            switch write {
            case .size(let size): AX.setSize(element, size)
            case .position(let origin): AX.setPosition(element, origin)
            }
        }
    }
}

/// Per-window request generation, shared between main and worker threads.
/// Uses one global monotonic counter rather than per-window counters: if a
/// window's entry were simply deleted on `remove`, a later window reusing
/// the same id could restart its counter at 1, and a stale queued request
/// carrying generation 1 would pass `isCurrent` again. With a global
/// counter, removing an id makes every outstanding generation for it stale
/// forever, and any later generation is strictly larger than every old one.
final class Generations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WindowID: UInt64] = [:]
    private var counter: UInt64 = 0

    func next(_ id: WindowID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        values[id] = counter
        return counter
    }

    func remove(_ id: WindowID) {
        lock.lock(); defer { lock.unlock() }
        values[id] = nil
    }

    func isCurrent(_ id: WindowID, _ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[id] == generation
    }
}
