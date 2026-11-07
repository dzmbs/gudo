import Foundation
import Testing
@testable import HostKit

struct TimelineValuesTests {
    private func roundTrip<Known>(_ type: Known.Type) throws
    where Known: RawRepresentable & Hashable & Sendable & CaseIterable, Known.RawValue == String {
        for tag in Known.allCases {
            let original = TimelineValue<Known>.known(tag)
            let encoded = try TimelineJSON.encode(original)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(tag.rawValue)\"")
            #expect(try JSONDecoder().decode(TimelineValue<Known>.self, from: encoded) == original)
        }
        let future = TimelineValue<Known>.unknown("FutureTag")
        let encoded = try TimelineJSON.encode(future)
        #expect(try JSONDecoder().decode(TimelineValue<Known>.self, from: encoded) == future)
        #expect(future.wireValue == "FutureTag")
    }

    @Test func allKnownAndFutureTagsRoundTripThroughTheirStringEncoding() throws {
        try roundTrip(TimelineAgentTag.self)
        try roundTrip(TimelineCommandSourceTag.self)
        try roundTrip(TimelinePermissionModeTag.self)
        try roundTrip(TimelinePlanStatusTag.self)
        try roundTrip(TimelineNoticeKindTag.self)
        try roundTrip(TimelineToolKindTag.self)
        try roundTrip(TimelineToolStatusTag.self)
        try roundTrip(TimelineFileChangeTag.self)
        try roundTrip(TimelineDiffLineKindTag.self)
        try roundTrip(TimelineFieldTag.self)
    }

    @Test func unknownNestedValuesNeverAcquireKnownSemantics() throws {
        let json = """
        {"cursor":{"epoch":1,"sequence":2},"before":null,
        "session":{"agent":"FutureAgent","native_session":"s","title":null,"model":null,
        "permission_mode":"future-mode","commands":[{"name":"review","description":"","source":"FutureSource"}]},
        "items":[{"id":"tool","revision":1,"turn":null,"parent":null,"at":0,"origin":"Agent",
        "body":{"Tool":{"kind":"FutureTool","name":"tool","title":"Tool","input":"{}","status":"FutureStatus",
        "output":null,"diff":[],"exit":null,"duration_ms":null,"command_mark":null}}}]}
        """
        let value = try TimelineJSON.decode(TimelineSnapshot.self, from: json)
        #expect(value.session.agent == .unknown("FutureAgent"))
        #expect(value.session.permissionMode == .unknown("future-mode"))
        #expect(value.session.commands.first?.source == .unknown("FutureSource"))
        guard case .tool(let tool) = value.items.first?.body else { Issue.record("Missing tool"); return }
        #expect(tool.kind == .unknown("FutureTool"))
        #expect(tool.status == .unknown("FutureStatus"))
        #expect(tool.status != .known(.running))
    }

    @Test func unknownAppendFieldsAreRetainedForFailClosedApplication() throws {
        let json = #"{"Append":{"cursor":{"epoch":1,"sequence":2},"id":"a","field":"FutureField","text":"tail"}}"#
        let value = try TimelineJSON.decode(TimelineOperation.self, from: json)
        guard case .append(_, _, let field, _) = value else { Issue.record("Missing append"); return }
        #expect(field == .unknown("FutureField"))
    }

    @Test func tagsMustStillBeStrings() {
        for json in ["42", "null", "{}"] {
            #expect(throws: (any Error).self) {
                try TimelineJSON.decode(TimelineToolStatus.self, from: json)
            }
        }
    }
}
