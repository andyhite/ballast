import CoreGraphics
import Testing
@testable import BallastCore

@Suite("MasterStackLayout")
struct MasterStackTests {

    static let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)

    // `side` names the STACK's side (StackSide / LayoutSettings.stackSide);
    // the master region occupies the opposite side.

    @Test("side right: stack on the right, master on the left")
    func sideRight() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .right, gap: 0)
        #expect(frames[1]!.minX == Self.rect.minX) // master on the left
        #expect(frames[2]!.maxX == Self.rect.maxX) // stack on the right
        #expect(frames[2]!.minX >= frames[1]!.maxX)
    }

    @Test("side left: stack on the left, master on the right")
    func sideLeft() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .left, gap: 0)
        #expect(frames[1]!.maxX == Self.rect.maxX) // master on the right
        #expect(frames[2]!.minX == Self.rect.minX) // stack on the left
        #expect(frames[1]!.minX >= frames[2]!.maxX)
    }

    @Test("side bottom: stack at the bottom, master at the top")
    func sideBottom() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .bottom, gap: 0)
        #expect(frames[1]!.minY == Self.rect.minY) // master on top
        #expect(frames[2]!.maxY == Self.rect.maxY) // stack on bottom
    }

    @Test("side top: stack at the top, master at the bottom")
    func sideTop() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .top, gap: 0)
        #expect(frames[1]!.maxY == Self.rect.maxY) // master on bottom
        #expect(frames[2]!.minY == Self.rect.minY) // stack on top
    }

    @Test("ratio is respected for master region extent")
    func ratioRespected() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.75, side: .right, gap: 0)
        #expect(abs(frames[1]!.width - 750) < 0.001)
        #expect(abs(frames[2]!.width - 250) < 0.001)
    }

    @Test("stack windows share the stack region equally")
    func stackWindowsEqual() {
        let frames = MasterStackLayout.frames(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0)
        #expect(frames[2]!.height == frames[3]!.height)
        #expect(abs(frames[2]!.height - Self.rect.height / 2) < 0.001)
    }

    @Test("gaps appear between tiles and never outside rect")
    func gapsBetweenTilesOnly() {
        let gap = 10.0
        let frames = MasterStackLayout.frames(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: gap)
        // No frame extends outside rect.
        for frame in frames.values {
            #expect(frame.minX >= Self.rect.minX - 0.001)
            #expect(frame.maxX <= Self.rect.maxX + 0.001)
            #expect(frame.minY >= Self.rect.minY - 0.001)
            #expect(frame.maxY <= Self.rect.maxY + 0.001)
        }
        // Gap between master (1, left) and stack (2, right).
        #expect(abs(frames[2]!.minX - frames[1]!.maxX) - gap < 0.5)
        // Gap between the two stacked windows (2 above 3).
        #expect(abs(frames[3]!.minY - frames[2]!.maxY) - gap < 0.5)
    }
    @Test("empty stack lets masters fill the whole area")
    func emptyStackFillsArea() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 2, ratio: 0.6, side: .right, gap: 0)
        // Masters tile along the cross axis (vertical for side .right/.left),
        // each spanning the rect's full width; heights sum to the rect's height.
        for frame in frames.values {
            #expect(abs(frame.width - Self.rect.width) < 0.001)
        }
        let totalHeight = frames.values.map(\.height).reduce(0, +)
        #expect(abs(totalHeight - Self.rect.height) < 0.001)
    }

    @Test("masterCount greater than window count is handled")
    func masterCountExceedsWindows() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 10, ratio: 0.6, side: .right, gap: 0)
        #expect(frames.count == 2)
        // All windows become masters, filling the rect (tiled along the cross axis).
        for frame in frames.values {
            #expect(abs(frame.width - Self.rect.width) < 0.001)
        }
        let totalHeight = frames.values.map(\.height).reduce(0, +)
        #expect(abs(totalHeight - Self.rect.height) < 0.001)
    }
    @Test("empty order yields no frames")
    func emptyOrderYieldsNoFrames() {
        let frames = MasterStackLayout.frames(order: [], in: Self.rect, masterCount: 1, ratio: 0.6, side: .right, gap: 0)
        #expect(frames.isEmpty)
    }
}
