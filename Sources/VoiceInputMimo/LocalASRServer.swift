import Foundation

/// Spawns and supervises the local MiMo ASR server (`server/server.py`).
///
/// Runs `python -m uvicorn server:app` directly — no shell wrapper. All knobs
/// (server dir / python path / port / precision / model root / preload) flow
/// through `Configuration`, which reads UserDefaults and exposes sensible
/// defaults for first-run.
///
/// Lifecycle:
///   • `start(completion:)` — fast-path returns success if `<port>` already serves
///     `/v1/health`; otherwise spawns python, then polls health until ready or
///     `startTimeout` elapses.
///   • `stop()` — terminates the spawned process. A pre-existing externally-managed
///     server is left untouched (see `weStartedIt`).
///   • Process stdout/stderr append to `logURL`.
final class LocalASRServer {
    static let shared = LocalASRServer()

    // MARK: - Configuration

    /// Server-launch knobs sourced from UserDefaults. All paths are tilde-expanded
    /// at read time. Modify via `Configuration.write(_:)` or directly through
    /// SettingsWindow; LocalASRServer reads on each `start()`.
    struct Configuration: Equatable {
        var serverDir: String
        var pythonPath: String
        var port: Int
        var precision: String       // "int4" | "bf16"
        var modelRoot: String
        var preload: Bool
        var module: String          // "engine.server:app" or "server:app"

        static let defaults = Configuration(
            serverDir: "~/Documents/voice-input-mimo-asr-engine".expandingTilde,
            pythonPath: "~/Documents/voice-input-mimo/server/.venv/bin/python".expandingTilde,
            port: 8766,
            precision: "int4",
            modelRoot: "~/.cache/mimo-asr".expandingTilde,
            preload: true,
            module: "engine.server:app"
        )

        static func current() -> Configuration {
            migrateIfNeeded()
            let d = UserDefaults.standard
            let serverDir = (d.string(forKey: "asrServerDir")?.nilIfEmpty ?? defaults.serverDir).expandingTilde
            let defaultPython = "\(serverDir)/.venv/bin/python"
            return Configuration(
                serverDir: serverDir,
                pythonPath: (d.string(forKey: "asrPythonPath")?.nilIfEmpty ?? defaultPython).expandingTilde,
                port: d.object(forKey: "asrServerPort") as? Int ?? defaults.port,
                precision: d.string(forKey: "asrPrecision")?.nilIfEmpty ?? defaults.precision,
                modelRoot: (d.string(forKey: "asrModelRoot")?.nilIfEmpty ?? defaults.modelRoot).expandingTilde,
                preload: (d.object(forKey: "asrServerPreload") as? Bool) ?? defaults.preload,
                module: d.string(forKey: "asrServerModule")?.nilIfEmpty ?? defaults.module
            )
        }

        /// One-shot migration from Engine-1 (server:app on 8765) to Engine-2 (engine.server:app on 8766).
        /// Idempotent via `engine2Migrated_v1` flag.
        private static func migrateIfNeeded() {
            let d = UserDefaults.standard
            if d.bool(forKey: "engine2Migrated_v1") { return }
            let oldServerDir = "/Users/shiun/Documents/voice-input-mimo/server"
            let isOldConfig = (d.string(forKey: "asrServerDir") == oldServerDir)
                || (d.object(forKey: "asrServerPort") as? Int == 8765)
            if isOldConfig {
                d.set(defaults.serverDir, forKey: "asrServerDir")
                d.set(defaults.port, forKey: "asrServerPort")
                d.set(defaults.module, forKey: "asrServerModule")
                d.set("http://127.0.0.1:\(defaults.port)", forKey: "asrBaseURL")
                NSLog("[LocalASRServer] Migrated to Engine-2 (port \(defaults.port), module \(defaults.module))")
            }
            d.set(true, forKey: "engine2Migrated_v1")
        }

        func write() {
            let d = UserDefaults.standard
            d.set(serverDir, forKey: "asrServerDir")
            d.set(pythonPath, forKey: "asrPythonPath")
            d.set(port, forKey: "asrServerPort")
            d.set(precision, forKey: "asrPrecision")
            d.set(modelRoot, forKey: "asrModelRoot")
            d.set(preload, forKey: "asrServerPreload")
            d.set(module, forKey: "asrServerModule")
        }

        /// First validation pass — surfaces obvious misconfigurations to the UI.
        func validate() -> ConfigurationError? {
            if !FileManager.default.fileExists(atPath: serverDir) {
                return .serverDirMissing(serverDir)
            }
            if !FileManager.default.fileExists(atPath: pythonPath) {
                return .pythonMissing(pythonPath)
            }
            // Resolve module to expected .py file: "engine.server:app" → "engine/server.py"
            let modulePath = module.split(separator: ":").first.map(String.init) ?? module
            let pyRel = modulePath.replacingOccurrences(of: ".", with: "/") + ".py"
            let pyAbs = (serverDir as NSString).appendingPathComponent(pyRel)
            if !FileManager.default.fileExists(atPath: pyAbs) {
                return .serverPyMissing(pyAbs)
            }
            if !(1...65535).contains(port) {
                return .invalidPort(port)
            }
            if !["int4", "bf16"].contains(precision) {
                return .invalidPrecision(precision)
            }
            return nil
        }
    }

    enum ConfigurationError: Error, LocalizedError {
        case serverDirMissing(String)
        case pythonMissing(String)
        case serverPyMissing(String)
        case invalidPort(Int)
        case invalidPrecision(String)

        var errorDescription: String? {
            switch self {
            case .serverDirMissing(let p): return "Server directory not found: \(p)"
            case .pythonMissing(let p): return "Python executable not found: \(p)"
            case .serverPyMissing(let p): return "server.py not found: \(p)"
            case .invalidPort(let n): return "Invalid port: \(n) (must be 1–65535)"
            case .invalidPrecision(let s): return "Invalid precision: \(s) (expected 'int4' or 'bf16')"
            }
        }
    }

    // MARK: - State

    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    enum LaunchError: Error, LocalizedError {
        case configInvalid(String)
        case healthTimeout
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .configInvalid(let msg): return msg
            case .healthTimeout: return "ASR server did not become ready within \(LocalASRServer.startTimeout)s."
            case .spawnFailed(let msg): return "Failed to start ASR server: \(msg)"
            }
        }
    }

    private(set) var state: State = .stopped {
        didSet {
            onStateChange?(state)
            if state == .running {
                startKeepalive()
            } else {
                stopKeepalive()
            }
        }
    }
    var onStateChange: ((State) -> Void)?

    private var process: Process?
    private var weStartedIt = false
    private var keepaliveTimer: Timer?

    static let startTimeout: TimeInterval = 30
    static let keepaliveInterval: TimeInterval = 30

    var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceInputMimo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("asr.log")
    }

    // MARK: - Public API

    /// Launches the server if needed, then waits for `/v1/health` to respond.
    /// Reads the latest `Configuration` on each call.
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        if case .running = state {
            completion(.success(()))
            return
        }

        let config = Configuration.current()
        if let err = config.validate() {
            state = .failed(err.localizedDescription)
            completion(.failure(LaunchError.configInvalid(err.localizedDescription)))
            return
        }

        state = .starting

        // Fast path: someone else (terminal, prior session) is already running it.
        ASRClient.shared.health { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.state = .running
                NSLog("[LocalASRServer] Detected pre-existing server on :\(config.port) — adopting (won't terminate on stop).")
                self.weStartedIt = false
                completion(.success(()))
                return
            }
            self.spawn(config: config, completion: completion)
        }
    }

    func stop() {
        if let proc = process, proc.isRunning, weStartedIt {
            NSLog("[LocalASRServer] terminating spawned server (pid=%d)", proc.processIdentifier)
            proc.terminate()
        } else if !weStartedIt {
            NSLog("[LocalASRServer] stop() ignored — server is externally managed.")
        }
        process = nil
        state = .stopped
    }

    /// Stop and start in one shot — useful after Settings change.
    func restart(completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start(completion: completion)
        }
    }

    /// Probe without side-effects. Updates `state` to `.running` / `.stopped`.
    func refresh(completion: ((Bool) -> Void)? = nil) {
        ASRClient.shared.health { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.state != .running { self.state = .running }
                completion?(true)
            case .failure:
                if self.state == .running { self.state = .stopped }
                completion?(false)
            }
        }
    }

    // MARK: - Private

    private func spawn(config: Configuration, completion: @escaping (Result<Void, Error>) -> Void) {
        // Truncate log so user sees only this attempt.
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let logHandle = (try? FileHandle(forWritingTo: logURL))
            ?? {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                return try? FileHandle(forWritingTo: logURL)
            }()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.pythonPath)
        proc.arguments = [
            "-u",                          // unbuffered → log appears in real time
            "-m", "uvicorn", config.module,
            "--host", "127.0.0.1",
            "--port", String(config.port),
            "--log-level", "info",
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.serverDir)

        var env = ProcessInfo.processInfo.environment
        env["MIMO_PRECISION"] = config.precision
        env["MIMO_MODEL_ROOT"] = config.modelRoot
        env["MIMO_PRELOAD"] = config.preload ? "1" : "0"
        env["PORT"] = String(config.port)  // belt-and-suspenders for any code reading PORT
        env["PYTHONPATH"] = config.serverDir   // engine.server:app needs serverDir on path
        proc.environment = env

        if let handle = logHandle {
            proc.standardOutput = handle
            proc.standardError = handle
        }
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let code = p.terminationStatus
            DispatchQueue.main.async {
                if self.state == .running || self.state == .starting {
                    self.state = code == 0 ? .stopped : .failed("ASR server exited with code \(code).")
                }
                self.process = nil
            }
        }

        do {
            try proc.run()
        } catch {
            let msg = error.localizedDescription
            NSLog("[LocalASRServer] spawn failed: %@", msg)
            state = .failed(msg)
            completion(.failure(LaunchError.spawnFailed(msg)))
            return
        }

        process = proc
        weStartedIt = true
        NSLog("[LocalASRServer] spawned %@ (pid=%d), polling /v1/health…", config.pythonPath, proc.processIdentifier)

        pollHealth(deadline: Date().addingTimeInterval(Self.startTimeout)) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.state = .running
                completion(.success(()))
            } else {
                self.state = .failed(LaunchError.healthTimeout.localizedDescription)
                completion(.failure(LaunchError.healthTimeout))
            }
        }
    }

    // MARK: - Keepalive

    /// Periodic `/v1/health` ping keeps the python interpreter and module imports
    /// in active pages (model weights are pinned by `MIMO_PRELOAD=1` already).
    private func startKeepalive() {
        stopKeepalive()
        let timer = Timer(timeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
            ASRClient.shared.health { result in
                if case .failure = result {
                    DispatchQueue.main.async { self?.refresh() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }

    private func pollHealth(deadline: Date, completion: @escaping (Bool) -> Void) {
        ASRClient.shared.health { [weak self] result in
            if case .success = result {
                completion(true)
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            if let proc = self?.process, !proc.isRunning {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.pollHealth(deadline: deadline, completion: completion)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
