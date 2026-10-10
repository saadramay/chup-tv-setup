import Foundation
import Combine
import AppKit

// MARK: - Models

/// A question the script is waiting on. `secure` means the answer must not be logged.
struct Prompt: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let secure: Bool
}

enum Outcome: Equatable {
    case success(String)
    case failure(String)
}

// MARK: - Stream helpers

/// The pipes hand us arbitrary chunks, so a line routinely arrives split across two reads.
/// Buffering is done under a lock because the read loops run on background queues.
final class LineSplitter {
    private var data = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: data[data.startIndex..<nl], as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }

    func rest() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return text
    }
}

private let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
private let stepRegex = try! NSRegularExpression(pattern: "^([1-7])/7[ \\t]+(.*)$")

func stripANSI(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\r", with: "")
    let range = NSRange(flat.startIndex..., in: flat)
    return ansiRegex.stringByReplacingMatches(in: flat, options: [], range: range, withTemplate: "")
}

// MARK: - Runner

/// Runs tv-setup.sh and turns its stdout/stderr into a log, a progress step and prompts.
final class Runner: ObservableObject {
    @Published var log = ""
    @Published var isRunning = false
    @Published var stepNumber = 0
    @Published var stepTitle = ""
    @Published var prompt: Prompt? = nil
    @Published var outcome: Outcome? = nil
    /// `::connected <serial>`: the script telling us the TV actually attached. Not a guess
    /// from mDNS -- the box answered.
    @Published var connectedSerial: String? = nil
    @Published var restartAfter = true
    @Published var fetchLatest = true

    /// The TV the wizard connected to in step 2. Handed to the script as CHUP_SERIAL so it
    /// uses that box directly instead of asking "which one is this TV?" all over again.
    var presetSerial: String? = nil

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var cancelled = false
    private var inputExhausted = false
    private let readers = DispatchGroup()

    // Hooks for headless use (--run), where there is no SwiftUI watching the published values.
    var onLog: ((String) -> Void)?
    var onPrompt: ((Prompt) -> Void)?
    var onFinished: ((Outcome) -> Void)?
    var onStoppedForQuit: (() -> Void)?

    private static let scriptEndpoint =
        "https://api.github.com/repos/saadramay/chup-tv-setup/contents/tv-setup.sh?ref=main"

    // MARK: lifecycle

    func start() {
        guard !isRunning else { return }
        log = ""
        stepNumber = 0
        stepTitle = ""
        prompt = nil
        outcome = nil
        connectedSerial = nil
        cancelled = false
        inputExhausted = false
        isRunning = true

        prepareScript { [weak self] url, note in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !note.isEmpty { self.appendLog(note) }
                guard let url = url else {
                    self.isRunning = false
                    self.finish(.failure(note.isEmpty ? "tv-setup.sh not found." : note))
                    return
                }
                self.launch(url: url)
            }
        }
    }

    func cancel() {
        guard let proc = process, proc.isRunning else { return }
        cancelled = true
        appendLog("\nStopping — restoring the TV as we found it...\n")
        proc.interrupt()                     // SIGINT, so the script's traps still run
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, let p = self.process, p.isRunning else { return }
            p.terminate()                    // SIGTERM
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, let p = self.process, p.isRunning else { return }
                kill(p.processIdentifier, SIGKILL)
                self.closePipes()
            }
        }
    }

    /// Give the script stdin EOF, so an answer that can no longer arrive fails the run instead
    /// of leaving it blocked on a read that will never be satisfied. The flag matters because
    /// this can arrive before launch() has created the pipe at all.
    func closeInput() {
        inputExhausted = true
        guard let handle = stdinHandle else { return }
        stdinHandle = nil
        try? handle.close()
    }

    /// The app is quitting while a run is in flight. Stop the script and wait for it, so its
    /// cleanup -- putting the TV's stay-on setting back -- happens before we disappear and
    /// close the pipes it is still writing to.
    func beginShutdown() {
        guard let proc = process, proc.isRunning else { reportStopped(); return }
        proc.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let p = self.process, p.isRunning else { return }
            p.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, let p = self.process, p.isRunning else { return }
                kill(p.processIdentifier, SIGKILL)
                self.closePipes()
                self.reportStopped()
            }
        }
    }

    private func reportStopped() {
        guard let done = onStoppedForQuit else { return }
        onStoppedForQuit = nil
        done()
    }

    func submit(_ answer: String) {
        guard prompt != nil, let handle = stdinHandle, let p = process, p.isRunning else { return }
        let secure = prompt?.secure ?? false
        prompt = nil
        if !secure {
            appendLog("  -> \(answer.isEmpty ? "(accept the default)" : answer)\n")
        }
        try? handle.write(contentsOf: Data((answer + "\n").utf8))
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log, forType: .string)
    }

    // MARK: sourcing the script

    /// The copy inside the app bundle. The guided setup needs it before any run starts,
    /// because `--prep` is what fetches adb.
    static func bundledScript() -> URL? {
        Bundle.main.url(forResource: "tv-setup", withExtension: "sh")
    }

    private func prepareScript(_ done: @escaping (URL?, String) -> Void) {
        guard let bundled = Runner.bundledScript() else {
            done(nil, "tv-setup.sh is missing from this copy of the app.")
            return
        }
        guard speaksGUI(bundled) else {
            done(nil, "The bundled tv-setup.sh does not speak this app's protocol. Rebuild with app/build.sh.")
            return
        }
        guard fetchLatest, let endpoint = URL(string: Runner.scriptEndpoint) else {
            done(bundled, "")
            return
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            let bundledNote: (String) -> String = { reason in
                "Couldn't fetch the latest script from GitHub (\(reason)). Using the copy bundled with this app.\n"
            }
            if let error = error {
                done(bundled, bundledNote(error.localizedDescription)); return
            }
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let base64 = object["content"] as? String,
                  let bytes = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")),
                  let text = String(data: bytes, encoding: .utf8),
                  text.hasPrefix("#!/bin/bash")
            else {
                done(bundled, bundledNote("unexpected reply")); return
            }
            // A copy that predates CHUP_UI would read from a terminal this app has not got,
            // and hang on the first prompt. Only ever run a script that speaks our protocol.
            guard text.contains("CHUP_UI") else {
                done(bundled, "The copy on GitHub does not speak this app's protocol yet; using the bundled copy.\n")
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("tv-setup-latest.sh")
            do {
                try text.write(to: destination, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: destination.path)
                done(destination, "Using the latest tv-setup.sh from GitHub.\n")
            } catch {
                done(bundled, bundledNote(error.localizedDescription))
            }
        }.resume()
    }

    private func speaksGUI(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("CHUP_UI")
    }

    // MARK: running

    private func launch(url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [url.path]

        var env = ProcessInfo.processInfo.environment
        env["CHUP_UI"] = "1"
        env["CHUP_RESTART"] = restartAfter ? "yes" : "no"
        if let serial = presetSerial, !serial.isEmpty {
            env["CHUP_SERIAL"] = serial
        }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let out = Pipe(), err = Pipe(), input = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input
        outPipe = out
        errPipe = err
        stdinHandle = input.fileHandleForWriting
        process = proc
        // The answering side may already have given up while we were still fetching the script.
        if inputExhausted { closeInput() }

        let outSplit = LineSplitter()
        let errSplit = LineSplitter()

        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let lines = outSplit.feed(chunk)
                if !lines.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.consumeStdout(lines) }
                }
            }
            self.readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = err.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let lines = errSplit.feed(chunk)
                if !lines.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.consumeStderr(lines) }
                }
            }
            self.readers.leave()
        }

        proc.terminationHandler = { [weak self] finished in
            // Only judge the result once both pipes have hit EOF, so the reason the script
            // stopped is already in the log.
            self?.readers.notify(queue: .main) {
                guard let self = self else { return }
                self.isRunning = false
                self.prompt = nil
                self.stdinHandle = nil
                self.process = nil
                if finished.terminationStatus == 0 {
                    self.finish(.success("Setup finished. Read the RustDesk ID off the TV to Chup support."))
                } else if self.cancelled {
                    self.finish(.failure("Cancelled before setup finished."))
                } else {
                    self.finish(.failure(self.stoppingReason()))
                }
                self.reportStopped()
            }
        }

        appendLog("$ bash tv-setup.sh\n")
        do {
            try proc.run()
        } catch {
            isRunning = false
            finish(.failure("Could not start the script: \(error.localizedDescription)"))
        }
    }

    private func closePipes() {
        try? outPipe?.fileHandleForReading.close()
        try? errPipe?.fileHandleForReading.close()
    }

    // MARK: consuming output

    private func consumeStdout(_ lines: [String]) {
        for raw in lines {
            let line = stripANSI(raw)
            if let (number, title) = step(from: line) {
                stepNumber = number
                stepTitle = title
            }
            appendLog(line + "\n")
        }
    }

    private func consumeStderr(_ lines: [String]) {
        for raw in lines {
            if raw.hasPrefix("::ask ") {
                var question = String(raw.dropFirst(6))
                let secure = question.hasPrefix("secure ")
                if secure { question = String(question.dropFirst(7)) }
                let created = Prompt(question: question, secure: secure)
                prompt = created
                onPrompt?(created)
                appendLog("  ? " + question + (secure ? "  (hidden)" : "") + "\n")
            } else if raw.hasPrefix("::connected ") {
                // A control line, not something anybody needs to read in the log: it is how
                // the rail learns the TV attached, and mDNS could never have told it.
                connectedSerial = String(raw.dropFirst(12))
            } else {
                let line = stripANSI(raw)
                guard !line.isEmpty else { continue }
                appendLog(line + "\n")
            }
        }
    }

    func step(from line: String) -> (Int, String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = stepRegex.firstMatch(in: line, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line),
              let number = Int(line[numberRange])
        else { return nil }
        return (number, line[titleRange].trimmingCharacters(in: .whitespaces))
    }

    /// The script's `die` writes "Stopped: ..." to stdout; that is the real reason.
    private func stoppingReason() -> String {
        for line in log.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Stopped:") { return text }
        }
        if let last = log.split(separator: "\n").last {
            return last.trimmingCharacters(in: .whitespaces)
        }
        return "The setup script failed."
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 400_000 { log = String(log.suffix(300_000)) }
        onLog?(text)
    }

    private func finish(_ outcome: Outcome) {
        self.outcome = outcome
        onFinished?(outcome)
    }
}
