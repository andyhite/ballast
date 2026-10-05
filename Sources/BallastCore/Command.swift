import Foundation

public enum Cycle: String, Equatable, Sendable {
    case next
    case prev
}

/// The documented command set. Bound to hotkeys in config, invoked from the
/// menu, or sent by `ballast send <command>`.
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case swap(Direction)
    case focusLast
    /// Focus the next or previous tiled window on the Space, in layout order, wrapping.
    case focusCycle(Cycle)
    /// Focus the feature (first tile); from the feature, return to the window
    /// focused before it.
    case focusFeature
    case promote
    /// The focused window joins the tile of its neighbor that way, which
    /// becomes a deck (windows layered in one tile) if it was not one.
    case deck(Direction)
    /// The focused window leaves its deck into its own tile after the deck.
    case undeck
    case reset
    /// Re-read the desktop's windows, forget the minimum sizes learned from
    /// refused frames, and re-send every tile's frame. Keeps the arrangement.
    case relayout
    case monocle
    case toggleFloat
    /// Close the focused window (its close button).
    case close
    /// Toggle native macOS full screen on the focused window.
    case fullscreen
    /// Bring every floating window on the Space to the front.
    case raiseFloats
    /// Move floating windows that are mostly off-screen back onto the current display.
    case rescue
    /// Grow (positive) or shrink (negative) the focused tile's share.
    case resize(Double)
    case featureSize(Double)
    case featureCount(Int)
    case balance
    case sendToDisplay(Cycle)
    case focusDisplay(Cycle)
    case reload
    case dumpState

    public static let reference: [String] = [
        "focus left|right|up|down", "focus next|prev", "focus-last", "focus-feature", "swap left|right|up|down",
        "deck left|right|up|down", "undeck",
        "promote", "reset", "relayout", "monocle", "float", "close", "fullscreen", "raise-floats", "rescue",
        "grow [amount]", "shrink [amount]", "feature-size <+/-delta>", "feature-count <+/-delta>",
        "balance", "send-to-display next|prev", "focus-display next|prev", "reload", "dump-state",
    ]

    public static func parse(_ text: String) -> Result<Command, CommandParseError> {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let verb = words.first else { return .failure(.init("empty command")) }
        let args = Array(words.dropFirst())
        let arg = args.first

        func direction() -> Result<Direction, CommandParseError> {
            guard args.count == 1, let arg, let d = Direction(rawValue: arg) else {
                return .failure(.init("'\(verb)' expects left|right|up|down"))
            }
            return .success(d)
        }
        func cycle() -> Result<Cycle, CommandParseError> {
            guard args.count == 1, let arg, let c = Cycle(rawValue: arg == "previous" ? "prev" : arg) else {
                return .failure(.init("'\(verb)' expects next|prev"))
            }
            return .success(c)
        }
        func noArgs(_ command: Command) -> Result<Command, CommandParseError> {
            args.isEmpty ? .success(command) : .failure(.init("'\(verb)' takes no arguments"))
        }
        func number(default value: Double?) -> Result<Double, CommandParseError> {
            guard let arg else {
                if let value { return .success(value) }
                return .failure(.init("'\(verb)' expects a number"))
            }
            guard args.count == 1 else {
                return .failure(.init("'\(verb)' takes one number"))
            }
            guard let v = Double(arg), v.isFinite else {
                return .failure(.init("'\(verb)': invalid number '\(arg)'"))
            }
            return .success(v)
        }

        switch verb {
        case "focus":
            if arg == "last", args.count == 1 { return .success(.focusLast) }
            if arg == "feature", args.count == 1 { return .success(.focusFeature) }
            if let arg, args.count == 1, ["next", "prev", "previous"].contains(arg) { return cycle().map(Command.focusCycle) }
            return direction().map(Command.focus)
        case "focus-last": return noArgs(.focusLast)
        case "focus-feature": return noArgs(.focusFeature)
        case "swap", "move": return direction().map(Command.swap)
        case "promote": return noArgs(.promote)
        case "deck": return direction().map(Command.deck)
        case "undeck": return noArgs(.undeck)
        case "reset": return noArgs(.reset)
        case "relayout", "re-layout": return noArgs(.relayout)
        case "monocle", "zoom": return noArgs(.monocle)
        case "float": return noArgs(.toggleFloat)
        case "close": return noArgs(.close)
        case "fullscreen": return noArgs(.fullscreen)
        case "raise-floats": return noArgs(.raiseFloats)
        case "rescue": return noArgs(.rescue)
        case "grow": return number(default: 0.05).map { .resize(abs($0)) }
        case "shrink": return number(default: 0.05).map { .resize(-abs($0)) }
        case "feature-size": return number(default: nil).map(Command.featureSize)
        case "feature-count":
            return number(default: nil).flatMap { v in
                guard v == v.rounded(), abs(v) <= 16 else { return .failure(.init("'feature-count' expects an integer delta within -16…16")) }
                return .success(.featureCount(Int(v)))
            }
        case "balance": return noArgs(.balance)
        case "send-to-display": return cycle().map(Command.sendToDisplay)
        case "focus-display": return cycle().map(Command.focusDisplay)
        case "reload": return noArgs(.reload)
        case "dump-state": return noArgs(.dumpState)
        default:
            return .failure(.init("unknown command '\(verb)'"))
        }
    }
}

public struct CommandParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
