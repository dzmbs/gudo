/// What the user set a Pencil double tap or squeeze to do in Settings ▸ Apple Pencil.
public enum PencilPreference: Sendable, Equatable {
    case switchEraser
    case switchPrevious
    /// A colour, ink or contextual palette: the toolbar is the palette here.
    case showPalette
    case ignore
}

/// Turns Pencil double taps and squeezes into tool switches, remembering the tool to go back to.
public struct PencilToolSwitch: Sendable, Equatable {
    public private(set) var previous: DrawTool?

    public init() {}

    /// The tool to switch to, or nil to stay on `current`.
    public mutating func respond(to preference: PencilPreference, current: DrawTool) -> DrawTool? {
        switch preference {
        case .ignore, .showPalette:
            return nil
        case .switchEraser:
            let next = current == .eraser ? (previous.flatMap { $0 == .eraser ? nil : $0 } ?? .pen) : .eraser
            previous = current
            return next
        case .switchPrevious:
            guard let back = previous, back != current else { return nil }
            previous = current
            return back
        }
    }
}

extension DrawRouting {
    /// On a canvas pane the Pencil inks through PencilKit with the pen and Select (fingers then
    /// select and pan); with a shape, text or the eraser it goes to the editor like a finger.
    public static func canvasPencilInks(editorTool type: String) -> Bool {
        switch DrawTool(excalidrawType: type) {
        case .pen, .select: true
        default: type == "hand"
        }
    }
}
