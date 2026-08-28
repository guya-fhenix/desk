import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ShellError: Error, CustomStringConvertible, Sendable {
    case executableNotFound(String)
    case failed(command: String, status: Int32, stderr: String)
    case timedOut(command: String)

    public var description: String {
        switch self {
        case .executableNotFound(let name): return "executable not found: \(name)"
        case .failed(let command, let status, let stderr): return "\(command) exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut(let command): return "\(command) timed out"
        }
    }
}

/// Runs one process without blocking any thread: pipes deliver data through readability handlers
/// and the termination handler completes the continuation once both pipes hit EOF.
private final class ProcessRun: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe: Pipe?
    private let stdin: Data?
    private let command: String
    private let timeout: TimeInterval

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitStatus: Int32?
    private var launched = false
    private var continuation: CheckedContinuation<ShellResult, any Error>?
    private var timeoutWork: DispatchWorkItem?

    init(executable: String, arguments: [String], cwd: String?, stdin: Data?, environment: [String: String], timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinPipe = stdin.map { _ in Pipe() }
        if let stdinPipe { process.standardInput = stdinPipe }
        self.stdin = stdin
        self.command = ([executable] + arguments).joined(separator: " ")
        self.timeout = timeout
    }

    func run() async throws -> ShellResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, any Error>) in
                lock.withLock { self.continuation = continuation }
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                    return
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        lock.withLock { stdoutClosed = true }
                        finishIfDone()
                    } else {
                        lock.withLock { stdout.append(data) }
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        lock.withLock { stderrClosed = true }
                        finishIfDone()
                    } else {
                        lock.withLock { stderr.append(data) }
                    }
                }
                process.terminationHandler = { [self] process in
                    lock.withLock { exitStatus = process.terminationStatus }
                    finishIfDone()
                }
                do {
                    try process.run()
                    lock.withLock { launched = true }
                } catch {
                    finish(.failure(error))
                    return
                }
                if let stdin, let stdinPipe {
                    stdinPipe.fileHandleForWriting.write(stdin)
                    try? stdinPipe.fileHandleForWriting.close()
                }
                let work = DispatchWorkItem { [self] in
                    terminateIfRunning()
                    finish(.failure(ShellError.timedOut(command: command)))
                }
                lock.withLock { timeoutWork = work }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
            }
        } onCancel: {
            terminateIfRunning()
            finish(.failure(CancellationError()))
        }
    }

    /// `Process.terminate()` raises an Objective-C exception on a process that never launched,
    /// and Swift cannot catch it. Cancellation can arrive before `run()`, so check first.
    private func terminateIfRunning() {
        let canSignal = lock.withLock { launched }
        guard canSignal, process.isRunning else { return }
        process.terminate()
    }

    private func finishIfDone() {
        let result: ShellResult? = lock.withLock {
            guard let exitStatus, stdoutClosed, stderrClosed else { return nil }
            return ShellResult(status: exitStatus, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
        }
        if let result { finish(.success(result)) }
    }

    private func finish(_ result: Result<ShellResult, any Error>) {
        let continuation: CheckedContinuation<ShellResult, any Error>? = lock.withLock {
            defer { self.continuation = nil }
            timeoutWork?.cancel()
            return self.continuation
        }
        guard let continuation else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(with: result)
    }
}

public enum Shell {
    public static let defaultTimeout: TimeInterval = 90

    /// Directories searched for tools when the app runs with a minimal GUI PATH.
    public static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    public static func which(_ name: String) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in toolDirectories + pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func run(
        _ executable: String, _ arguments: [String], cwd: String? = nil, stdin: Data? = nil,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShellError.executableNotFound(executable)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (toolDirectories + [environment["PATH"] ?? ""]).joined(separator: ":")
        let run = ProcessRun(executable: executable, arguments: arguments, cwd: cwd, stdin: stdin, environment: environment, timeout: timeout)
        return try await run.run()
    }

    /// Runs a command and returns stdout. Throws when the exit status is not zero.
    @discardableResult
    public static func output(
        _ executable: String, _ arguments: [String], cwd: String? = nil, stdin: Data? = nil,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let result = try await run(executable, arguments, cwd: cwd, stdin: stdin, timeout: timeout)
        guard result.status == 0 else {
            throw ShellError.failed(command: ([executable] + arguments).joined(separator: " "), status: result.status, stderr: result.stderr)
        }
        return result.text
    }
}
