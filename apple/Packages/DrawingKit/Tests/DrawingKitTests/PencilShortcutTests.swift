import DrawingKit
import Testing

@Suite struct PencilShortcutTests {
    @Test func switchEraserGoesToTheEraserAndBack() {
        var toolSwitch = PencilToolSwitch()
        #expect(toolSwitch.respond(to: .switchEraser, current: .rectangle) == .eraser)
        #expect(toolSwitch.respond(to: .switchEraser, current: .eraser) == .rectangle)
    }

    @Test func switchEraserFromTheEraserWithNothingBeforeIsThePen() {
        var toolSwitch = PencilToolSwitch()
        #expect(toolSwitch.respond(to: .switchEraser, current: .eraser) == .pen)
    }

    @Test func switchPreviousTogglesTheLastTwoTools() {
        var toolSwitch = PencilToolSwitch()
        #expect(toolSwitch.respond(to: .switchPrevious, current: .pen) == nil, "nothing to go back to yet")
        _ = toolSwitch.respond(to: .switchEraser, current: .pen)
        #expect(toolSwitch.respond(to: .switchPrevious, current: .eraser) == .pen)
        #expect(toolSwitch.respond(to: .switchPrevious, current: .pen) == .eraser)
    }

    @Test func palettesAndIgnoreLeaveTheTool() {
        var toolSwitch = PencilToolSwitch()
        #expect(toolSwitch.respond(to: .ignore, current: .pen) == nil)
        #expect(toolSwitch.respond(to: .showPalette, current: .pen) == nil)
        #expect(toolSwitch.previous == nil)
    }

    @Test func thePencilInksOnACanvasOnlyWithThePenSelectOrHand() {
        #expect(DrawRouting.canvasPencilInks(editorTool: "freedraw"))
        #expect(DrawRouting.canvasPencilInks(editorTool: "selection"))
        #expect(DrawRouting.canvasPencilInks(editorTool: "hand"))
        #expect(!DrawRouting.canvasPencilInks(editorTool: "rectangle"))
        #expect(!DrawRouting.canvasPencilInks(editorTool: "eraser"))
        #expect(!DrawRouting.canvasPencilInks(editorTool: "text"))
    }
}
