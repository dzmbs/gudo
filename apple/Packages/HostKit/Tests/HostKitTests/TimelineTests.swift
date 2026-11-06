import Foundation
import Testing
@testable import HostKit

struct TimelineTests {
    private let snapshot = #"{"cursor":{"epoch":18446744073709551615,"sequence":18446744073709551614},"session":{"agent":"Claude","native_session":"fixture","title":null,"model":"fixture-model","permission_mode":"default","commands":[]},"items":[{"id":"m1","revision":1,"turn":"t1","parent":null,"at":42,"origin":"Terminal","body":{"User":{"text":"Hello 🦀","attachments":[{"path":"/tmp/photo.png","media_type":"image/png"}],"queued":false}}}],"before":100}"#

    @Test func snapshotPreservesIntegerCursorsAndRoundTrips() throws {
        let value = try TimelineJSON.decode(TimelineSnapshot.self, from: snapshot)
        #expect(value.cursor.epoch == UInt64.max)
        #expect(value.cursor.sequence == UInt64.max - 1)
        #expect(value.session.nativeSession == "fixture")
        #expect(value.items.first?.origin == .terminal)
        guard case .user(let user) = value.items.first?.body else { Issue.record("Missing user"); return }
        #expect(user.text == "Hello 🦀")
        #expect(user.attachments.first?.mediaType == "image/png")
        let encoded = try TimelineJSON.encode(value)
        #expect(try TimelineJSON.decode(TimelineSnapshot.self, from: String(decoding: encoded, as: UTF8.self)) == value)
    }

    @Test func everyOperationDecodesTheRustExternalTagShape() throws {
        let json = """
        {"pane_id":18446744073709551615,"operations":[
        {"Snapshot":\(snapshot)},
        {"Upsert":{"cursor":{"epoch":1,"sequence":2},"item":{ "id":"a","revision":2,"turn":null,"parent":null,"at":50,"origin":"Agent","body":{"Assistant":{"text":"Answer","streaming":true}}}}},
        {"Append":{"cursor":{"epoch":1,"sequence":3},"id":"a","field":"Text","text":" tail"}},
        {"Remove":{"cursor":{"epoch":1,"sequence":4},"id":"a"}},
        {"Session":{"cursor":{"epoch":1,"sequence":5},"session":{"agent":"Codex","native_session":"same-thread","title":null,"model":null,"permission_mode":null,"commands":[]}}},
        {"Unavailable":{"message":"Open Terminal"}},
        {"Checkpoint":{"cursor":{"epoch":1,"sequence":6}}}
        ]}
        """
        let value = try TimelineJSON.decode(TimelineUpdate.self, from: json)
        #expect(value.paneId == UInt64.max)
        #expect(value.operations.count == 7)
        guard case .append(let cursor, let id, let field, let text) = value.operations[2] else { Issue.record("Missing append"); return }
        #expect(cursor.sequence == 3)
        #expect(id == "a" && field == "Text" && text == " tail")
        guard case .session(_, let session) = value.operations[4] else { Issue.record("Missing session"); return }
        #expect(session.nativeSession == "same-thread")
    }

    @Test func allBodyKindsDecodeAndRoundTrip() throws {
        let bodies = [
            #"{"Thinking":{"text":"Reason","duration_ms":12}}"#,
            #"{"Plan":{"entries":[{"text":"Test","status":"Completed"}]}}"#,
            #"{"Notice":{"kind":"Compacted","text":"Summary"}}"#,
            #"{"TurnEnd":{"duration_ms":19,"input_tokens":100,"output_tokens":42}}"#,
            #"{"Tool":{"kind":"Shell","name":"Bash","title":"Run tests","input":"cargo test","status":"Done","output":{"handle":"opaque","preview":"ok","bytes":2},"diff":[],"exit":0,"duration_ms":5,"command_mark":null}}"#
        ]
        for json in bodies {
            let body = try TimelineJSON.decode(TimelineBody.self, from: json)
            let encoded = try TimelineJSON.encode(body)
            #expect(try TimelineJSON.decode(TimelineBody.self, from: String(decoding: encoded, as: UTF8.self)) == body)
        }
    }

    @Test func malformedOrUnknownContentIsNotSilentlyInterpreted() {
        #expect(throws: (any Error).self) { try TimelineJSON.decode(TimelineBody.self, from: #"{"FutureBlock":{}}"#) }
        #expect(throws: (any Error).self) { try TimelineJSON.decode(TimelineOperation.self, from: #"{"Append":{"cursor":{"epoch":1,"sequence":2}}}"#) }
    }
}
