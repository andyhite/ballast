import Foundation

public enum LayoutMode: String, CaseIterable, Equatable, Sendable {
    case masterStack = "master_stack"
    case bsp
    case float

    /// Compact menu-bar glyph.
    public var glyph: String {
        switch self {
        case .masterStack: return "MS"
        case .bsp: return "BSP"
        case .float: return "⋯"
        }
    }
}

public enum LayoutChange: Equatable, Sendable {
    case set(LayoutMode)
    case next
    case previous
    /// Drop the manual mode override; follow the config again.
    case configDefault
}

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
    case promote
    case reset
    case layout(LayoutChange)
    case monocle
    case toggleFloat
    /// Grow (positive) or shrink (negative) the focused tile's share.
    case resize(Double)
    case masterRatio(Double)
    case masterCount(Int)
    case balance
    case sendToDisplay(Cycle)
    case focusDisplay(Cycle)
    case reload
    case dumpState

    public static let reference: [String] = [
        "focus left|right|up|down", "focus-last", "swap left|right|up|down",
        "promote", "reset", "layout master_stack|bsp|float|next|prev|default", "monocle", "float",
        "grow [amount]", "shrink [amount]", "master-ratio <+/-delta>", "master-count <+/-delta>",
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
            guard args.count == 1, let v = Double(arg), v.isFinite else {
                return .failure(.init("'\(verb)': invalid number '\(arg)'"))
            }
            return .success(v)
        }

        switch verb {
        case "focus":
            if arg == "last", args.count == 1 { return .success(.focusLast) }
            return direction().map(Command.focus)
        case "focus-last": return noArgs(.focusLast)
        case "swap", "move": return direction().map(Command.swap)
        case "promote": return noArgs(.promote)
        case "reset": return noArgs(.reset)
        case "layout":
            guard args.count == 1, let arg else { return .failure(.init("'layout' expects a mode, next, prev or default")) }
            switch arg {
            case "next": return .success(.layout(.next))
            case "prev", "previous": return .success(.layout(.previous))
            case "default": return .success(.layout(.configDefault))
            default:
                guard let mode = LayoutMode(rawValue: arg) else {
                    return .failure(.init("unknown layout '\(arg)' (master_stack|bsp|float)"))
                }
                return .success(.layout(.set(mode)))
            }
        case "monocle", "zoom": return noArgs(.monocle)
        case "float": return noArgs(.toggleFloat)
        case "grow": return number(default: 0.05).map { .resize(abs($0)) }
        case "shrink": return number(default: 0.05).map { .resize(-abs($0)) }
        case "master-ratio": return number(default: nil).map(Command.masterRatio)
        case "master-count":
            return number(default: nil).flatMap { v in
                guard v == v.rounded(), abs(v) <= 16 else { return .failure(.init("'master-count' expects an integer delta")) }
                return .success(.masterCount(Int(v)))
            }
        case "balance": return noArgs(.balance)
        case "send-to-display": return cycle().map(Command.sendToDisplay)
        case "focus-display": return cycle().map(Command.focusDisplay)
        case "reload": return noArgs(.reload)
        case "dump-state": return noArgs(.dumpState)
        default: return .failure(.init("unknown command '\(verb)'"))
        }
    }
}

public struct CommandParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
