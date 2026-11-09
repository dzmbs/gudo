import Testing
@testable import TerminalRenderer

struct KeyToScreenTests {
    @Test func aKeyIsTimedThroughEachStageToTheFrameShowingItsEcho() throws {
        let timer = KeyToScreen()
        timer.keyReceived(at: 10.000, sentAt: 10.002)
        timer.outputArrived(serial: 7, at: 10.030)
        let frame = try #require(timer.frameEncoding(showingOutput: 7, showsLocalEcho: false, at: 10.034))
        timer.framePresented(frame, at: 10.041)

        let summary = try #require(timer.drain())
        #expect(summary.count == 1)
        #expect(summary.toEcho.p50 == 41)
        #expect(summary.keyToSent.p50 == 2)
        #expect(summary.sentToOutput.p50 == 28)
        #expect(summary.outputToFrame.p50 == 4)
        #expect(summary.frameToScreen.p50 == 7)
        #expect(summary.toFeedback.p50 == 41)
    }

    @Test func aPredictedEchoIsFeedbackBeforeTheHostAnswers() throws {
        let timer = KeyToScreen()
        timer.keyReceived(at: 5.000, sentAt: 5.001)
        let predicted = try #require(timer.frameEncoding(showingOutput: 0, showsLocalEcho: true, at: 5.004))
        timer.framePresented(predicted, at: 5.012)
        timer.outputArrived(serial: 1, at: 5.060)
        let echoed = try #require(timer.frameEncoding(showingOutput: 1, showsLocalEcho: false, at: 5.062))
        timer.framePresented(echoed, at: 5.070)

        let summary = try #require(timer.drain())
        #expect(summary.toFeedback.p50 == 12)
        #expect(summary.toEcho.p50 == 70)
    }

    @Test func aFrameWithNeitherTheEchoNorAPredictionIsNotFeedback() throws {
        let timer = KeyToScreen()
        timer.keyReceived(at: 1.000, sentAt: 1.001)
        timer.outputArrived(serial: 3, at: 1.020)
        #expect(timer.frameEncoding(showingOutput: 2, showsLocalEcho: false, at: 1.021) == nil)
        let frame = try #require(timer.frameEncoding(showingOutput: 3, showsLocalEcho: false, at: 1.040))
        timer.framePresented(frame, at: 1.050)
        #expect(timer.drain()?.toEcho.p50 == 50)
    }

    @Test func keysTypedWhileOneIsInFlightAreNotTimed() throws {
        let timer = KeyToScreen()
        timer.keyReceived(at: 1.000, sentAt: 1.001)
        timer.keyReceived(at: 1.010, sentAt: 1.011)
        timer.outputArrived(serial: 1, at: 1.020)
        let frame = try #require(timer.frameEncoding(showingOutput: 1, showsLocalEcho: false, at: 1.021))
        timer.framePresented(frame, at: 1.030)
        #expect(timer.drain()?.toEcho.p50 == 30)
    }

    @Test func aKeyWithNoAnswerIsAbandoned() {
        let timer = KeyToScreen()
        timer.keyReceived(at: 1.000, sentAt: 1.001)
        timer.outputArrived(serial: 1, at: 1.000 + KeyToScreen.abandonAfter + 0.1)
        #expect(timer.frameEncoding(showingOutput: 1, showsLocalEcho: true, at: 2.2) == nil)
        timer.keyReceived(at: 3.000, sentAt: 3.001)
        #expect(timer.frameEncoding(showingOutput: 1, showsLocalEcho: true, at: 3.002) != nil)
    }

    @Test func aFrameThatNeverReachedTheScreenIsNotCounted() throws {
        let timer = KeyToScreen()
        timer.keyReceived(at: 1.000, sentAt: 1.001)
        timer.outputArrived(serial: 1, at: 1.010)
        let frame = try #require(timer.frameEncoding(showingOutput: 1, showsLocalEcho: false, at: 1.011))
        timer.framePresented(frame, at: 0)
        #expect(timer.drain() == nil)
        let presented = try #require(timer.frameEncoding(showingOutput: 1, showsLocalEcho: false, at: 1.020))
        timer.framePresented(presented, at: 1.028)
        #expect(timer.drain()?.toEcho.p50 == 28)
    }

    @Test func percentilesSpanTheSamples() throws {
        let timer = KeyToScreen()
        for index in 1...100 {
            let start = Double(index)
            timer.keyReceived(at: start, sentAt: start)
            timer.outputArrived(serial: UInt64(index), at: start)
            let frame = try #require(timer.frameEncoding(showingOutput: UInt64(index), showsLocalEcho: false, at: start))
            timer.framePresented(frame, at: start + Double(index) / 1000)
        }
        let summary = try #require(timer.drain())
        #expect(summary.count == 100)
        #expect(summary.toEcho.p50 == 50)
        #expect(summary.toEcho.p95 == 95)
        #expect(summary.toEcho.p99 == 99)
        #expect(summary.toEcho.max == 100)
        #expect(timer.drain() == nil)
    }
}
