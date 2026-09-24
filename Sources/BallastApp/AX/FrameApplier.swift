import ApplicationServices
import BallastCore
import Foundation

/// Mutation path. Owns one serial queue per application, so an app that is
/// slow to answer AX (Electron, Java) only delays its own windows. Receives
/// plain frame requests; never touches engine state; reports results back to
/// the main thread.
final class FrameApplier {
    struct Request {
        let window: WindowID
        let pid: pid_t
        let element: AXUIElement
        let target: CGRect
        /// Interpolate from the current frame (focused window on the active Space only).
        let animation: (duration: Double, easing: Easing, frameInterval: Double)?
    }

    /// Outcome of one request, delivered on the main thread.
    struct Outcome {
        /// Frame read back after applying; nil when AX could not be read.
        let actual: CGRect?
        /// False when a newer request superseded this one mid-way: `actual`
        /// is then an intermediate frame and says nothing about constraints.
        let completed: Bool
    }

    typealias Completion = (WindowID, CGRect, Outcome) -> Void

    private var queues: [pid_t: DispatchQueue] = [:]
    private let generations = Generations()

    /// Main thread.
    func apply(_ request: Request, completion: @escaping Completion) {
        let generation = generations.next(request.window)
        let generations = self.generations
        let q = queue(for: request.pid)
        q.async {
            Self.run(request, generation: generation, generations: generations, queue: q) { result in
                DispatchQueue.main.async { completion(request.window, request.target, result) }
            }
        }
    }

    /// Runs arbitrary AX work (focus, raise, attribute writes) on the app's worker.
    func perform(pid: pid_t, _ work: @escaping () -> Void) {
        queue(for: pid).async(execute: work)
    }

    /// Stops any in-flight animation for `window` at its next frame.
    func cancel(_ window: WindowID) { _ = generations.next(window) }

    func forget(pid: pid_t) { queues[pid] = nil }

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
        completion: @escaping (Outcome) -> Void
    ) {
        guard let start = AX.frame(r.element) else { completion(Outcome(actual: nil, completed: false)); return }
        guard generations.isCurrent(r.window, generation) else {
            completion(Outcome(actual: start, completed: false))
            return
        }
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
        completion: @escaping (Outcome) -> Void
    ) {
        let deadlineNanos = begin + UInt64(min(frameIndex * anim.frameInterval * 1_000_000_000, total))
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = DispatchTime(uptimeNanoseconds: max(deadlineNanos, now))
        queue.asyncAfter(deadline: deadline) {
            // Stale generation check happens before any further AX read.
            guard generations.isCurrent(r.window, generation) else {
                completion(Outcome(actual: AX.frame(r.element), completed: false))
                return
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin)
            let t = elapsed / total
            if t >= 1 {
                finish(r, current: current, completion: completion)
                return
            }
            let p = anim.easing.apply(t)
            let step = CGRect(x: start.minX + (r.target.minX - start.minX) * p,
                              y: start.minY + (r.target.minY - start.minY) * p,
                              width: start.width + (r.target.width - start.width) * p,
                              height: start.height + (r.target.height - start.height) * p).integral
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
    private static func finish(_ r: Request, current: CGRect, completion: @escaping (Outcome) -> Void) {
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

    /// Shrinking: size first, then position. Growing: position first, then
    /// size. Either way the window never extends past its destination
    /// mid-transition (so it can't clip off the display).
    private static func set(_ element: AXUIElement, from: CGRect, to: CGRect) {
        let sizeChanged = !from.size.equalTo(to.size)
        let moved = !from.origin.equalTo(to.origin)
        let shrinking = to.width <= from.width && to.height <= from.height
        if shrinking {
            if sizeChanged { AX.setSize(element, to.size) }
            if moved { AX.setPosition(element, to.origin) }
        } else {
            if moved { AX.setPosition(element, to.origin) }
            if sizeChanged { AX.setSize(element, to.size) }
        }
    }
}

/// Per-window request generation, shared between main and worker threads.
private final class Generations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WindowID: UInt64] = [:]

    func next(_ id: WindowID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let v = (values[id] ?? 0) &+ 1
        values[id] = v
        return v
    }

    func isCurrent(_ id: WindowID, _ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[id] == generation
    }
}
