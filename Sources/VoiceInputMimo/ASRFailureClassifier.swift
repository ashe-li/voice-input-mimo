import Foundation

/// Pure, testable rules extracted from `AppDelegate` so the capture-sizing
/// threshold and ASR error-mapping can be unit tested without standing up the
/// AppKit app. `AppDelegate.runASR` / `transcribeJob` are the only callers.

/// Decides whether a recorded WAV is too small to be worth sending to ASR.
///
/// The signal is the declared size of the WAV `data` chunk, NOT the file size.
/// AVAudioRecorder pre-allocates a ~4 KB file padded with a `FLLR` filler chunk
/// and a `data` chunk whose size it finalizes on stop. When a capture is stopped
/// before any frames land, the file is still ~4 KB on disk but the `data` chunk
/// declares size 0 — which the ASR engine rejects with HTTP 500 "Input is too
/// short (length=0)". We parse that declared size and, below ~0.1 s of payload,
/// treat the clip as "No speech detected" instead of POSTing it.
enum ASRAudioGuard {
    /// 3 200 B ≈ 0.1 s at 16 kHz mono 16-bit. Real speech — even a clipped
    /// "Yeah." (~0.2 s, 6 400 B) — is comfortably above this.
    static let minPCMBytes = 3_200
    /// The `data` chunk header sits right after fmt + FLLR padding (~4 KB in
    /// practice); 8 KB of header is plenty to locate it regardless of clip length.
    private static let headerScanBytes = 8_192

    static func isEffectivelyEmpty(declaredDataSize: Int) -> Bool {
        declaredDataSize < minPCMBytes
    }

    /// Parse the declared byte count of the WAV `data` chunk from a header buffer.
    /// Returns nil if the buffer isn't RIFF/WAVE or no `data` chunk is found
    /// within it (caller then treats the file as non-empty / best-effort).
    static func declaredDataChunkSize(headerBytes data: Data) -> Int? {
        let b = [UInt8](data)
        guard matches(b, 0, "RIFF"), matches(b, 8, "WAVE") else { return nil }
        var off = 12
        while off + 8 <= b.count {
            let size = Int(b[off + 4]) | Int(b[off + 5]) << 8
                | Int(b[off + 6]) << 16 | Int(b[off + 7]) << 24
            if matches(b, off, "data") { return size }
            // Chunks are word-aligned: odd sizes carry a pad byte.
            off += 8 + size + (size & 1)
        }
        return nil
    }

    /// Best-effort: if the file can't be opened / parsed, return false so the
    /// normal transcribe path raises its own fileRead error.
    static func isEffectivelyEmpty(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headerScanBytes)) ?? Data()
        guard let size = declaredDataChunkSize(headerBytes: head) else { return false }
        return isEffectivelyEmpty(declaredDataSize: size)
    }

    private static func matches(_ b: [UInt8], _ off: Int, _ ascii: String) -> Bool {
        let a = Array(ascii.utf8)
        guard off + a.count <= b.count else { return false }
        for i in 0..<a.count where b[off + i] != a[i] { return false }
        return true
    }
}

/// How an ASR failure should be surfaced to the user.
enum ASRFailureKind: Equatable {
    /// Sub-minimum / silence-only clip — benign "No speech detected".
    case emptyTranscript
    /// Couldn't reach the gateway at all (:4000 down). Not auto-startable.
    case backendUnreachable
    /// Gateway up but the ASR sidecar returned 502/503/504 — we just tried to
    /// (re)start it, so a retry usually succeeds.
    case backendNotReady
    /// Anything else — show the raw error unchanged.
    case passthrough
}

enum ASRFailureClassifier {
    static func classify(_ error: Error) -> ASRFailureKind {
        if let asrError = error as? ASRClient.ASRError,
           case .httpError(let code, let body) = asrError {
            if code == 500, body.contains("too short") {
                return .emptyTranscript
            }
            if [502, 503, 504].contains(code) {
                return .backendNotReady
            }
            return .passthrough
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut:
                return .backendUnreachable
            default:
                return .passthrough
            }
        }
        return .passthrough
    }
}
