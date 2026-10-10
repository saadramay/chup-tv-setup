import Foundation
import Network

/// Where a scan saw the box. It decides the caption under the address and which button the
/// row gets: a pairing code is needed for one of these and not for the others.
enum DeviceSource: Equatable {
    /// mDNS pairing service: that TV's pairing screen is open, so it is not paired yet.
    case pairingService
    /// mDNS connect service: this Mac is already paired with it.
    case connectService
    /// A plain adb daemon on port 5555. Older boxes have no Wireless debugging at all and so
    /// never advertise over mDNS -- tv-setup.sh sweeps the subnet for exactly this port for
    /// that reason, and an mDNS-only scan finds nothing on a network the script sees fine.
    case port5555
}

/// A box this Mac could set up, from whichever scan method found it, before anything is
/// attached to it.
struct DeviceEntry: Identifiable, Equatable {
    let addr: String
    let source: DeviceSource
    var pairing: Bool { source == .pairingService }
    /// The line under the address saying how the box was found.
    var hint: String {
        switch source {
        case .pairingService: return "Pairing screen open"
        case .connectService: return "Already paired"
        case .port5555:       return "Found on this Wi-Fi"
        }
    }
    /// One row per box: a box is only ever seen once, whatever port it was seen on.
    var id: String { addr }
}

/// Everything the app itself needs from this Mac: find adb, fetch it when it is missing,
/// find boxes on the network, attach to one, and drop a connection left over from an earlier
/// run. Installing and configuring the box is tv-setup.sh's half; which box is the TV is
/// always the person's answer -- this class finds candidates and connects on request, and
/// never picks one for them.
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

    /// adb and ipconfig write far less than a pipe holds in these calls, so reading after
    /// the process exits is safe.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
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
    /// mDNS only sees boxes offering Wireless debugging, so the subnet sweep for a plain
    /// adb daemon on port 5555 runs alongside it — that is the half of tv-setup.sh's
    /// find_devices an mDNS-only scan was missing, and the reason the script found boxes
    /// on this network that the app did not.
    ///
    /// A TV advertises its connect service whether or not this Mac is paired with it, so a
    /// pairing service for the same IP wins: that screen being open means it is not paired yet,
    /// and picking the connect entry would try to attach to a box that will refuse.
    static func scanDevices(_ adb: String) -> [DeviceEntry] {
        // Start the sweep first: it runs while mDNS is polled, so the scan stays about as
        // slow as the polling alone.
        let sweep = DispatchGroup()
        var portOpen: [String] = []
        sweep.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            portOpen = scanADBPort()
            sweep.leave()
        }

        var best: [DeviceEntry] = []
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
        sweep.wait()

        // One entry per IP: a pairing service beats a connect service for the same address,
        // and a box mDNS already knows beats a bare port that is open on the same address.
        var byIP: [String: DeviceEntry] = [:]
        for e in best {
            let ip = host(of: e.addr)
            if let existing = byIP[ip] {
                if e.pairing && !existing.pairing { byIP[ip] = e }
            } else {
                byIP[ip] = e
            }
        }
        for ip in portOpen where byIP[ip] == nil {
            byIP[ip] = DeviceEntry(addr: ip + ":5555", source: .port5555)
        }
        return byIP.values.sorted { $0.addr < $1.addr }
    }

    /// tv-setup.sh's scan_adb_port: probe this Mac's /24 for an adb daemon on port 5555.
    ///
    /// Every address is probed at once with a short timeout, so the sweep is over in about a
    /// second whatever the network does. The state callbacks of all 254 connections and their
    /// timeouts are dispatched to one serial queue, which is what keeps them from racing.
    static func scanADBPort(timeout: TimeInterval = 1.0) -> [String] {
        guard let prefix = localPrefix() else { return [] }
        let queue = DispatchQueue(label: "chup-setup.adb-port-probe")   // serial: no locking
        let group = DispatchGroup()
        var open: [String] = []
        for i in 1...254 {
            let host = "\(prefix).\(i)"
            let nwHost = NWEndpoint.Host(host)
            guard let port = NWEndpoint.Port(rawValue: 5555) else { continue }
            let conn = NWConnection(host: nwHost, port: port, using: .tcp)
            var settled = false      // exactly one group.leave() per probe, however many states arrive
            group.enter()
            conn.stateUpdateHandler = { state in
                var hit = false, finish = false
                if !settled {
                    switch state {
                    case .ready:                 settled = true; hit = true; finish = true
                    case .failed, .cancelled:    settled = true; finish = true
                    default: break
                    }
                }
                if hit { open.append(host) }
                if finish {
                    conn.cancel()
                    group.leave()
                }
            }
            conn.start(queue: queue)
            // A filtered address never fails on its own: cancel it so the sweep still ends.
            queue.asyncAfter(deadline: .now() + timeout) { conn.cancel() }
        }
        group.wait()
        return open.sorted()
    }

    /// This Mac's /24, read the way tv-setup.sh reads it: en0, then en1. With no address
    /// there is no subnet to sweep and the scan falls back to mDNS alone.
    static func localPrefix() -> String? {
        for iface in ["en0", "en1"] {
            let ip = run("/usr/sbin/ipconfig", ["getifaddr", iface]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = ip.split(separator: ".")
            if parts.count == 4 { return parts.dropLast().map(String.init).joined(separator: ".") }
        }
        return nil
    }

    /// The whole of a no-code attach, synchronously: drop whatever is left over from an earlier
    /// run, open a fresh connection, then ask the box what it is. Returns the serial it is
    /// attached as, or an empty serial with a problem in words the person can act on.
    static func attach(_ adb: String, _ addr: String) -> (serial: String, problem: String) {
        // A box that denied the debugging popup never asks again on the same connection, so
        // a retry has to open a fresh one. Emulators and USB devices have no port to drop.
        if addr.contains(":") { _ = run(adb, ["disconnect", addr], timeout: 10) }
        let (_, out) = run(adb, ["connect", addr])
        let lower = out.lowercased()
        if lower.contains("cannot connect") || lower.contains("failed to connect") || lower.contains("unable to connect") {
            let raw = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("", raw.isEmpty ? "Connection failed." : raw)
        }
        let (_, state) = run(adb, ["-s", addr, "get-state"])
        let s = state.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "device" { return (addr, "") }
        // "unauthorized" is the ordinary answer for a box found on the network for the first
        // time, and "connected to <addr>" is not a useful thing to show for it.
        if s.contains("unauthorized") {
            return ("", "The box is asking on its own screen: tick \"Always allow from this computer\", press OK, then press Connect again.")
        }
        return ("", "The box answered but adb says it is \"\(s.isEmpty ? "not answering" : s)\". Press Connect to try again.")
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
        let ip = host(of: addr)
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

    /// The address without its port, so a box is one row however many ports it showed up on.
    static func host(of addr: String) -> String {
        guard let colon = addr.lastIndex(of: ":") else { return addr }
        return String(addr[..<colon])
    }

    private static func entries(in text: String) -> [DeviceEntry] {
        var found: [DeviceEntry] = []
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            let source: DeviceSource
            if lower.contains("_adb-tls-pairing._tcp") { source = .pairingService }
            else if lower.contains("_adb-tls-connect._tcp") { source = .connectService }
            else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let addr = parts.last.map(String.init), addr.contains(":") else { continue }
            let entry = DeviceEntry(addr: addr, source: source)
            if !found.contains(entry) { found.append(entry) }
        }
        return found
    }
}
