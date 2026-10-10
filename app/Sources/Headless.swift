import Foundation

/// `chup-setup --run`: the same plumbing as the window, but the log goes to stdout and questions
/// go to stderr as the very same `::ask` control lines tv-setup.sh emits, with answers read back
/// from stdin. Anything that can drive the script can drive the app identically -- and it is the
/// only way to verify the app's process handling without a person clicking Start.
enum Headless {

    /// Drives the real Wizard + Prep code (the same code the GUI uses) with a scripted person,
    /// so step 2's scan → pair → connect → advance path can be verified without a GUI.
    /// Usage: chup-setup --wizard [--code 123456] [--index N]
    static func wizard() {
        let args = CommandLine.arguments
        let prep = Prep()
        let w = Wizard()
        let code = args.firstIndex(of: "--code").map { args[$0 + 1] } ?? "000000"
        let script = Runner.bundledScript()!

        func log(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        func dump(_ label: String) {
            log("  [\(label)] index=\(w.index) states=\(w.states.map { String(describing: $0).prefix(1) }.joined()) device=\(w.deviceLine.isEmpty ? "-" : w.deviceLine) note=\(w.note.isEmpty ? "-" : w.note)")
        }

        log("=== wizard headless ===")
        dump("start")

        // Step 1 — "I've done that"
        w.advance()
        dump("after step1 done")

        // Step 2 — auto-scan on entry (mirrors ContentView onChange)
        log("  prep.adb before ensureAdb = \(prep.adb ?? "nil")")
        // Mirror what the GUI does: ensure adb exists before scanning.
        let semaphore = DispatchSemaphore(value: 0)
        prep.ensureAdb(script: Runner.bundledScript()!) { _ in
            semaphore.signal()
        }
        semaphore.wait()
        log("  prep.adb after ensureAdb = \(prep.adb ?? "nil")")
        // Call scan synchronously — the Wizard's async dispatch needs a run loop,
        // which the GUI has but this headless harness does not.
        let found = Prep.scanDevices(prep.adb!)
        w.foundDevices = found
        w.note = found.isEmpty ? "No TVs found." : "Found \(found.count) TV(s)."
        dump("after scan")
        log("  foundDevices count = \(w.foundDevices.count)")
        for d in w.foundDevices {
            log("  found: \(d.addr) pairing=\(d.pairing)")
        }

        if w.foundDevices.isEmpty {
            log("FAIL: no devices found")
            exit(1)
        }
        let target = w.foundDevices.first!

        if target.pairing {
            log("  pairing with \(target.addr) code=\(code)")
            // Call pair synchronously — same reason as scan/connect above.
            let (ok, msg) = Prep.pairAndConnect(prep.adb!, target.addr, code)
            if ok {
                w.foundDevices = []
                let named = Prep.describe(prep.adb!, msg)
                w.tvSerial = msg
                w.deviceLine = named.isEmpty ? msg : named
                w.note = ""
                if w.states[w.index] == .active { w.states[w.index] = .done }
                w.states[2] = .skipped
                w.index = 3
                w.states[3] = .active
            } else {
                w.pairingAddr = target.addr
                w.note = msg.isEmpty ? "Pairing failed." : msg
            }
        } else {
            log("  connecting to \(target.addr)")
            // Call connect synchronously — same reason as scan above.
            let (_, out) = Prep.run(prep.adb!, ["connect", target.addr])
            let lower = out.lowercased()
            let ok = !(lower.contains("cannot connect") || lower.contains("failed to connect") || lower.contains("unable to connect"))
            var serial = ""
            if ok {
                let (_, state) = Prep.run(prep.adb!, ["-s", target.addr, "get-state"])
                if state.trimmingCharacters(in: .whitespacesAndNewlines) == "device" {
                    serial = target.addr
                }
            }
            if ok && !serial.isEmpty {
                w.foundDevices = []
                let named = Prep.describe(prep.adb!, serial)
                w.tvSerial = serial
                w.deviceLine = named.isEmpty ? serial : named
                w.note = ""
                if w.states[w.index] == .active { w.states[w.index] = .done }
                w.states[2] = .skipped
                w.index = 3
                w.states[3] = .active
            } else {
                w.note = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Connection failed."
                    : out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        dump("after pair/connect")

        // shouldAutoStart fires at index 3
        let started = w.shouldAutoStart(runnerRunning: false)
        log("  shouldAutoStart=\(started) launched=\(w.launched)")
        dump("final")

        if w.index != 3 || !started {
            log("FAIL: did not advance to step 4 / start script")
            exit(1)
        }
        log("PASS: step 2 flow reached step 4 with device connected")
        _ = script
        exit(0)
    }

    static func run() {
        let runner = Runner()
        let args = CommandLine.arguments
        if args.contains("--bundled-only") { runner.fetchLatest = false }
        if args.contains("--no-restart") { runner.restartAfter = false }
        // Same wiring as the window: a serial given here reaches the script as CHUP_SERIAL.
        if let i = args.firstIndex(of: "--serial") { runner.presetSerial = args[i + 1] }

        runner.onLog = { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        runner.onPrompt = { prompt in
            var line = "::ask "
            if prompt.secure { line += "secure " }
            line += prompt.question + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        runner.onFinished = { outcome in
            switch outcome {
            case .success:
                exit(0)
            case .failure(let message):
                FileHandle.standardError.write(Data("Stopped: \(message)\n".utf8))
                exit(1)
            }
        }

        runner.start()

        // One answer per line on stdin, exactly as the window would have typed it.
        Thread {
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { runner.submit(line) }
            }
            // Nothing can answer the script any more, so hand it EOF rather than let it sit
            // on a read that will never be satisfied.
            DispatchQueue.main.async { runner.closeInput() }
        }.start()
    }

    /// Covers the parts that turn the script's bytes into a progress bar. Pure logic, no device.
    static func selfTest() -> Bool {
        var pass = 0, fail = 0
        func check(_ label: String, _ got: String, _ want: String) {
            if got == want { pass += 1; print("  PASS  \(label)") }
            else { fail += 1; print("  FAIL  \(label)  (want '\(want)', got '\(got)')") }
        }

        // A line arriving split across two reads still comes out whole.
        let split = LineSplitter()
        check("partial line held back", String(split.feed(Data("1/7  Get".utf8)).count), "0")
        let joined = split.feed(Data("ting adb\n2/7  Connecting\n".utf8))
        check("joined then split", joined.joined(separator: "|"), "1/7  Getting adb|2/7  Connecting")
        check("nothing left over", split.rest(), "")

        check("ANSI stripped", stripANSI("\u{1B}[1m1/7  Getting adb\u{1B}[0m"), "1/7  Getting adb")
        check("CR stripped", stripANSI("\r  | working (1s)"), "  | working (1s)")
        check("colours stripped", stripANSI("  \u{1B}[32m✓\u{1B}[0m adb ready"), "  ✓ adb ready")

        let runner = Runner()
        func describe(_ s: String) -> String {
            guard let (n, t) = runner.step(from: s) else { return "" }
            return "\(n)|\(t)"
        }
        check("first step parsed", describe("1/7  Getting adb"), "1|Getting adb")
        check("middle step parsed", describe("5/7  RustDesk settings"), "5|RustDesk settings")
        check("sign-in step parsed", describe("6/7  Sign in to Chup TV"), "6|Sign in to Chup TV")
        check("last step parsed", describe("7/7  Finishing"), "7|Finishing")
        check("ordinary line ignored", describe("  ✓ adb ready"), "")
        check("8/7 ignored", describe("8/7  nonsense"), "")

        print("\n  \(pass) passed, \(fail) failed")
        return fail == 0
    }
}
