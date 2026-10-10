import Foundation

/// A TV as adb's mDNS browser sees it, before anything is attached.
struct MdnsEntry: Identifiable, Equatable {
    let addr: String
    let pairing: Bool
    var id: String { addr + (pairing ? "-pair" : "-connect") }
}

/// Everything the app itself needs from this Mac: find adb, fetch it when it is missing, say
/// what a device is, and drop a connection left over from an earlier run.
///
/// Finding the TV, listing the TVs and attaching to one all belong to tv-setup.sh -- it asks
/// the person which device is the TV, and this class deliberately has no say in that.
///
/// The work is done on a background queue; published values are only ever set on main.
final class Prep: ObservableObject {
    @Published var adb: String?
    @Published var lastError = ""
    @Published var working = false

    // MARK: finding adb

    /// Same search order as tv-setup.sh: PATH first, then the copy it downloads.
    static func findADB() -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            let path = dir + "/adb"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let path = NSHomeDirectory() + "/.chup-tv-setup/platform-tools/adb"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// adb has to exist before anything can talk to the box, and the script is the one thing
    /// that knows how to fetch it (our pinned release, then Google's mirror).
    func ensureAdb(script: URL, done: @escaping (Bool) -> Void) {
        if let found = Prep.findADB() {
            adb = found
            done(true)
            return
        }
        working = true
        lastError = ""
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("chup-prep.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "--prep"]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = handle
            p.standardError = handle
            var succeeded = false
            do {
                try p.run()
                p.waitUntilExit()
                succeeded = p.terminationStatus == 0
            } catch {}
            try? handle?.close()

            DispatchQueue.main.async {
                self.working = false
                if succeeded, let path = Prep.findADB() {
                    self.adb = path
                    done(true)
                } else {
                    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    self.lastError = "Could not get adb ready.\n" + text.suffix(400)
                    done(false)
                }
            }
        }
    }

    // MARK: talking to adb

    /// adb writes far less than a pipe holds in these calls, so reading after it exits is safe.
    static func run(_ adb: String, _ args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice        // adb swallowing stdin breaks callers
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func describe(_ adb: String, _ serial: String) -> String {
        let model = run(adb, ["-s", serial, "shell", "getprop", "ro.product.model"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = run(adb, ["-s", serial, "shell", "getprop", "ro.build.version.release"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty && version.isEmpty { return serial }
        return [model, version.isEmpty ? nil : "Android \(version)"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The device adb has really attached, if any. Emulators are ignored — there is always one
    /// running on this Mac and it is never the TV.
    static func alreadyAttached(_ adb: String) -> String? {
        let (_, text) = run(adb, ["devices"])
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            if !serial.hasPrefix("emulator-") { return serial }
        }
        return nil
    }

    /// Drop the TV from adb's list so every run has to find it and attach to it again. A
    /// connection left over from an earlier run can read as "device" while being half-dead --
    /// the port it was opened on is long gone by then -- and trusting it is how the wizard ends
    /// up stuck on a box it cannot actually talk to. Emulators are left alone.
    static func clearConnection(_ adb: String) {
        guard let serial = alreadyAttached(adb) else { return }
        _ = run(adb, ["disconnect", serial], timeout: 10)
    }

    /// One manual scan: run mdns services a few times and return the richest response
    /// (most adb-tls lines). adb's mdns browser sometimes returns only one service type
    /// per call, or stale cached results. This matches tv-setup.sh's mdns_quick logic.
    ///
    /// A TV advertises its connect service whether or not this Mac is paired with it, so a
    /// pairing service for the same IP wins: that screen being open means it is not paired yet,
    /// and picking the connect entry would try to attach to a box that will refuse.
    static func scanDevices(_ adb: String) -> [MdnsEntry] {
        var best: [MdnsEntry] = []
        var bestCount = 0
        for _ in 1...4 {
            let (_, text) = run(adb, ["mdns", "services"])
            let found = entries(in: text)
            if found.count > bestCount {
                best = found
                bestCount = found.count
            }
            Thread.sleep(forTimeInterval: 1)
        }
        // One entry per IP: a pairing service beats a connect service for the same address.
        var byIP: [String: MdnsEntry] = [:]
        for e in best {
            let ip = String(e.addr.dropLast(String(e.addr.split(separator: ":").last ?? "").count + 1))
            if let existing = byIP[ip] {
                if e.pairing && !existing.pairing { byIP[ip] = e }
            } else {
                byIP[ip] = e
            }
        }
        return byIP.values.sorted { $0.addr < $1.addr }
    }

    /// Pair with a code, then connect. Returns (true, serial) on success, (false, error) on failure.
    /// Mirrors tv-setup.sh's pair_wireless + connect_wait: pair, wait 2s for the TV to move to
    /// its new connect port, re-scan mDNS for that new port, then connect with retries.
    static func pairAndConnect(_ adb: String, _ addr: String, _ code: String) -> (Bool, String) {
        let (_, pairOut) = run(adb, ["pair", addr, code])
        let pairLower = pairOut.lowercased()
        if !(pairLower.contains("successfully paired") || pairLower.hasPrefix("paired")) {
            return (false, pairOut.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Pairing changes the connect port. Wait 2s then re-scan for the new one.
        Thread.sleep(forTimeInterval: 2)
        let ip = String(addr.dropLast(String(addr.split(separator: ":").last ?? "").count + 1))
        var newAddr = ""
        for _ in 1...6 {
            let (_, text) = run(adb, ["mdns", "services"])
            for line in text.split(separator: "\n") {
                let lower = line.lowercased()
                if lower.contains("_adb-tls-connect._tcp") {
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
                    if let a = parts.last.map(String.init), a.hasPrefix(ip + ":") {
                        newAddr = a
                        break
                    }
                }
            }
            if !newAddr.isEmpty { break }
            Thread.sleep(forTimeInterval: 2)
        }
        if newAddr.isEmpty {
            return (false, "paired but could not find new connect port")
        }
        // Connect with retries (like connect_wait in the script)
        for _ in 1...40 {
            let (_, connOut) = run(adb, ["connect", newAddr])
            let connLower = connOut.lowercased()
            if !(connLower.contains("cannot connect") || connLower.contains("failed to connect") || connLower.contains("unable to connect")) {
                let (_, state) = run(adb, ["-s", newAddr, "get-state"])
                if state.trimmingCharacters(in: .whitespacesAndNewlines) == "device" {
                    return (true, newAddr)
                }
            }
            Thread.sleep(forTimeInterval: 3)
        }
        return (false, "could not connect to \(newAddr)")
    }

    private static func entries(in text: String) -> [MdnsEntry] {
        var found: [MdnsEntry] = []
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            let isPairing: Bool
            if lower.contains("_adb-tls-pairing._tcp") { isPairing = true }
            else if lower.contains("_adb-tls-connect._tcp") { isPairing = false }
            else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let addr = parts.last.map(String.init), addr.contains(":") else { continue }
            let entry = MdnsEntry(addr: addr, pairing: isPairing)
            if !found.contains(entry) { found.append(entry) }
        }
        return found
    }
}
