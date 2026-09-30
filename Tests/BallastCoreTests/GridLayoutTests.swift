import CoreGraphics
import Testing
@testable import BallastCore

@Suite("GridLayout")
struct GridLayoutTests {
    static let landscape = CGRect(x: 0, y: 0, width: 900, height: 600)
    static let portrait = CGRect(x: 0, y: 0, width: 600, height: 900)

    /// Frames in window order for windows `1...count`.
    static func frames(_ count: Int, in rect: CGRect, gap: Double = 0,
                       minSize: (WindowID) -> CGSize = { _ in .zero }) -> [CGRect] {
        let plan = GridLayout.plan(order: Array(1...count).map { WindowID($0) }, in: rect, gap: gap, minSize: minSize)
        return (1...count).compactMap { plan.frames[WindowID($0)] }
    }

    @Test("one window fills the area; two split it along the long side")
    func oneAndTwo() {
        #expect(Self.frames(1, in: Self.landscape) == [Self.landscape])
        #expect(Self.frames(2, in: Self.landscape) == [
            CGRect(x: 0, y: 0, width: 450, height: 600), CGRect(x: 450, y: 0, width: 450, height: 600),
        ])
        #expect(Self.frames(2, in: Self.portrait) == [
            CGRect(x: 0, y: 0, width: 600, height: 450), CGRect(x: 0, y: 450, width: 600, height: 450),
        ])
    }

    @Test("an incomplete last row's windows split its full width")
    func incompleteLastRow() {
        let landscape = Self.frames(3, in: Self.landscape)
        #expect(landscape[0] == CGRect(x: 0, y: 0, width: 450, height: 300))
        #expect(landscape[1] == CGRect(x: 450, y: 0, width: 450, height: 300))
        #expect(landscape[2] == CGRect(x: 0, y: 300, width: 900, height: 300))

        let five = Self.frames(5, in: Self.landscape)
        #expect(five[2] == CGRect(x: 600, y: 0, width: 300, height: 300))
        #expect(five[3] == CGRect(x: 0, y: 300, width: 450, height: 300))
        #expect(five[4] == CGRect(x: 450, y: 300, width: 450, height: 300))

        let seven = Self.frames(7, in: Self.landscape)
        #expect(seven[5] == CGRect(x: 600, y: 200, width: 300, height: 200))
        #expect(seven[6] == CGRect(x: 0, y: 400, width: 900, height: 200))
    }

    @Test("a portrait area takes ceil(sqrt(n)) rows, filled row-major")
    func portraitShapes() {
        let three = Self.frames(3, in: Self.portrait)
        #expect(three[0] == CGRect(x: 0, y: 0, width: 300, height: 450))
        #expect(three[2] == CGRect(x: 0, y: 450, width: 600, height: 450))

        let five = Self.frames(5, in: Self.portrait)
        #expect(five[1] == CGRect(x: 300, y: 0, width: 300, height: 300))
        #expect(five[4] == CGRect(x: 0, y: 600, width: 600, height: 300))

        let seven = Self.frames(7, in: Self.portrait)
        #expect(seven[0] == CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(seven[5] == CGRect(x: 400, y: 300, width: 200, height: 300))
        #expect(seven[6] == CGRect(x: 0, y: 600, width: 600, height: 300))
    }

    @Test("inner gaps separate rows and cells")
    func gaps() {
        let frames = Self.frames(4, in: Self.landscape, gap: 10)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 445, height: 295))
        #expect(frames[1] == CGRect(x: 455, y: 0, width: 445, height: 295))
        #expect(frames[2] == CGRect(x: 0, y: 305, width: 445, height: 295))
        #expect(frames[3] == CGRect(x: 455, y: 305, width: 445, height: 295))
    }

    @Test("learned minimum sizes are honored, and the others share what is left")
    func minimumSizes() {
        let wide = Self.frames(2, in: Self.landscape) { $0 == 1 ? CGSize(width: 600, height: 0) : .zero }
        #expect(wide[0].width == 600 && wide[1].width == 300)

        let tall = Self.frames(3, in: Self.landscape) { $0 == 3 ? CGSize(width: 0, height: 450) : .zero }
        #expect(tall[2].height == 450 && tall[0].height == 150 && tall[2].maxY == 600)
    }

    @Test("no windows, or a degenerate area, never produce bad frames")
    func totality() {
        #expect(GridLayout.plan(order: [], in: Self.landscape, gap: 8).frames.isEmpty)
        let plan = GridLayout.plan(order: [1, 2, 3, 4, 5], in: .zero, gap: 8)
        #expect(plan.frames.count == 5)
        #expect(plan.frames.values.allSatisfy { $0.width >= 0 && $0.height >= 0 && $0.origin.x.isFinite })
    }
}
