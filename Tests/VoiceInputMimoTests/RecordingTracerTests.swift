import XCTest
@testable import VoiceInputMimo

final class RecordingTracerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: TraceStore!
    private var stepClock: Date!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-tracer-tests-\(UUID().uuidString)")
        store = TraceStore(rootDirectory: tempRoot)
        stepClock = Date(timeIntervalSinceReferenceDate: 0)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// Each call advances the clock by 1 second so log entry timestamps
    /// are deterministic and ordered.
    private func tickingNow() -> () -> Date {
        return { [unowned self] in
            defer { stepClock = stepClock.addingTimeInterval(1) }
            return stepClock
        }
    }

    private func makeTracer(id: String = "trace-FIXED01") -> RecordingTracer {
        RecordingTracer(
            store: store,
            now: tickingNow(),
            idGenerator: { id }
        )
    }

    // MARK: - Lifecycle

    func testBeginCreatesTraceWithStartStage() {
        let tracer = makeTracer()
        let trace = tracer.begin()
        XCTAssertEqual(trace.id, "trace-FIXED01")
        XCTAssertEqual(trace.logEntries.count, 1)
        XCTAssertEqual(trace.logEntries.first?.stage, .start)
        XCTAssertEqual(tracer.currentTrace?.id, "trace-FIXED01")
    }

    func testRecordMethodsAreNoopBeforeBegin() {
        let tracer = makeTracer()
        tracer.recordASR("nope")
        tracer.recordLLM("nope")
        tracer.recordFinal("nope")
        tracer.recordError("nope")
        XCTAssertNil(tracer.currentTrace)
    }

    func testFinalizeWithoutBeginReturnsNil() throws {
        let tracer = makeTracer()
        XCTAssertNil(tracer.finalize())
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

    // MARK: - Happy path

    func testFullPipelineHappyPathAppendsTraceWithAllStages() throws {
        let tracer = makeTracer()
        tracer.begin()
        tracer.recordAudio(path: "/tmp/audio.wav", bytes: 12345, sampleRate: 16000)
        tracer.recordASR("你好")
        tracer.recordLLM("Hello", mode: "claudeCode")
        tracer.recordClipboard(timestamp: "2026-05-14T10:00:00Z")
        tracer.recordFinal("Hello")
        tracer.finalize()

        let saved = try store.loadAll()
        XCTAssertEqual(saved.count, 1)
        let trace = try XCTUnwrap(saved.first)
        XCTAssertEqual(trace.id, "trace-FIXED01")
        XCTAssertEqual(trace.audioPath, "/tmp/audio.wav")
        XCTAssertEqual(trace.audioBytes, 12345)
        XCTAssertEqual(trace.sampleRate, 16000)
        XCTAssertEqual(trace.asrText, "你好")
        XCTAssertEqual(trace.llmText, "Hello")
        XCTAssertEqual(trace.finalText, "Hello")
        XCTAssertEqual(trace.mode, "claudeCode")
        XCTAssertEqual(trace.clipboardTimestamp, "2026-05-14T10:00:00Z")
        XCTAssertEqual(
            trace.logEntries.map(\.stage),
            [.start, .recording, .asrDone, .refineDone, .archived, .injectDone]
        )
        XCTAssertNotNil(trace.endedAt)
    }

    func testFinalizeClearsCurrentTrace() throws {
        let tracer = makeTracer()
        tracer.begin()
        tracer.recordASR("x")
        XCTAssertNotNil(tracer.currentTrace)
        tracer.finalize()
        XCTAssertNil(tracer.currentTrace)
    }

    // MARK: - Raw path (no LLM)

    func testRawPathSkipsLLMStage() throws {
        let tracer = makeTracer()
        tracer.begin()
        tracer.recordAudio(path: "/tmp/x.wav")
        tracer.recordASR("純文字")
        tracer.recordClipboard(timestamp: "2026-05-14T10:00:00Z")
        tracer.recordFinal("純文字")
        tracer.finalize()

        let saved = try store.loadAll()
        XCTAssertEqual(saved.count, 1)
        let trace = try XCTUnwrap(saved.first)
        XCTAssertNil(trace.llmText)
        XCTAssertEqual(
            trace.logEntries.map(\.stage),
            [.start, .recording, .asrDone, .archived, .injectDone]
        )
    }

    // MARK: - Error / cancel

    func testRecordErrorStillAllowsFinalize() throws {
        let tracer = makeTracer()
        tracer.begin()
        tracer.recordASR("partial")
        tracer.recordError("LLM 503")
        tracer.finalize()

        let saved = try store.loadAll()
        XCTAssertEqual(saved.count, 1)
        let trace = try XCTUnwrap(saved.first)
        XCTAssertEqual(trace.asrText, "partial")
        XCTAssertNil(trace.finalText)
        XCTAssertEqual(trace.logEntries.last?.stage, .error)
        XCTAssertEqual(trace.logEntries.last?.note, "LLM 503")
        XCTAssertNotNil(trace.endedAt)
    }

    func testCancelDropsTraceWithoutPersisting() throws {
        let tracer = makeTracer()
        tracer.begin()
        tracer.recordASR("dropped")
        tracer.cancel()
        XCTAssertNil(tracer.currentTrace)
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

    // MARK: - Park mode

    func testParkModeRecordsPathWithoutInject() throws {
        let tracer = makeTracer()
        tracer.begin()
        tracer.recordASR("park content")
        tracer.recordPark()
        tracer.finalize()

        let saved = try store.loadAll()
        XCTAssertEqual(saved.count, 1)
        let trace = try XCTUnwrap(saved.first)
        XCTAssertEqual(trace.mode, "park")
        XCTAssertNil(trace.finalText)
        XCTAssertEqual(trace.logEntries.last?.stage, .park)
        XCTAssertNotNil(trace.endedAt)
    }

    // MARK: - Begin after begin

    func testSecondBeginDiscardsPreviousTraceWithoutPersisting() throws {
        // Cycling ids so first begin returns FIRST, second returns SECOND.
        var ids = ["trace-FIRST", "trace-SECOND"]
        let tracer = RecordingTracer(
            store: store,
            now: tickingNow(),
            idGenerator: {
                guard !ids.isEmpty else { return "trace-EXTRA" }
                return ids.removeFirst()
            }
        )

        tracer.begin()
        tracer.recordASR("first")
        // Caller forgot to finalize() before starting the next session;
        // the previous trace's data must be dropped, not silently saved.
        let second = tracer.begin()
        XCTAssertEqual(second.id, "trace-SECOND")
        XCTAssertEqual(tracer.currentTrace?.id, "trace-SECOND")
        XCTAssertEqual(tracer.currentTrace?.asrText, "")
        XCTAssertEqual(tracer.currentTrace?.logEntries.map(\.stage), [.start])

        tracer.finalize()
        let saved = try store.loadAll()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, "trace-SECOND")
    }
}
