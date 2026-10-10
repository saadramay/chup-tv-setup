import Foundation

enum StepState: Equatable {
    case pending
    case active
    case done
    case skipped
    case failed
}

/// How a step reaches `done`. It decides what the detail pane shows and what it waits for.
enum StepKind {
    /// You do it on the remote; nothing in this app can see it, so it waits for you.
    case manual
    /// The scan looks for two kinds of box: one offering Wireless debugging (adb finds it by
    /// mDNS) and one with adb already open on port 5555 (the scan sweeps the subnet for it).
    case discover
    /// adb attaches — and asks for a pairing code first if the box insists.
    case connect
    /// tv-setup.sh owns this one; the rail mirrors its progress markers.
    case script
}

struct WizardStep: Identifiable {
    let id: Int
    let title: String
    /// What happens, or what you do — one short line at a time.
    let how: [String]
    /// What the app is doing while you read that, or what it is waiting for.
    let expect: String
    let kind: StepKind
}

extension WizardStep {
    static let all: [WizardStep] = [
        WizardStep(
            id: 1,
            title: "Turn on Developer options",
            how: [
                "Press Home, then open Settings — the gear at the top right.",
                "System, then About.",
                "Tap \"Android TV OS build\" seven times.",
                "The box says \"You are now a developer\"."
            ],
            expect: "This is the one step the app cannot see from here — it needs the remote.",
            kind: .manual
        ),
        WizardStep(
            id: 2,
            title: "Turn on Wireless debugging",
            how: [
                "Settings, System, Developer options.",
                "Scroll to \"Wireless debugging\" and switch it on.",
                "Leave that screen open — it has the pairing code you will need next."
            ],
            expect: "Press Scan to find TVs on this network. Pair the one showing a pairing code, or press Connect on a box that is already set up.",
            kind: .discover
        ),
        WizardStep(
            id: 3,
            title: "Connect to the TV",
            how: [],
            expect: "The TV answered and is attached. Nothing to do here — the install starts next.",
            kind: .connect
        ),
        WizardStep(
            id: 4,
            title: "Install the apps",
            how: [
                "Downloading Chup TV and RustDesk.",
                "Installing them on the box.",
                "Granting the permissions remote support needs."
            ],
            expect: "Runs by itself. The log at the bottom shows exactly what it is doing.",
            kind: .script
        ),
        WizardStep(
            id: 5,
            title: "Turn on remote support",
            how: [
                "Start RustDesk when the box boots.",
                "Set the permanent password.",
                "Turn on the share-screen service."
            ],
            expect: "If it wants a password, the field appears here — it is never typed on the TV.",
            kind: .script
        ),
        WizardStep(
            id: 6,
            title: "Sign in to Chup TV",
            how: [
                "Open Chup TV.",
                "Type the 6-digit code from the dashboard.",
                "Confirm the home screen comes up."
            ],
            expect: "You will be asked for the code. It goes straight into the box and is kept out of the log.",
            kind: .script
        ),
        WizardStep(
            id: 7,
            title: "Restart and check",
            how: [
                "Restart the TV.",
                "Wait for RustDesk to come back on its own.",
                "Re-check that everything survived the reboot."
            ],
            expect: "The last stretch. Nothing else is needed from you.",
            kind: .script
        )
    ]
}

/// Where you are in the guided setup: the rail's current step, its states, and the decisions
/// that move you forward. `Prep` supplies what adb sees; `Runner` supplies what the script says.
final class Wizard: ObservableObject {
    @Published var index = 0
    @Published var states: [StepState]

    @Published var note = ""
    @Published var deviceLine = ""

    /// The raw adb serial of the TV we connected to in step 2. The script gets it as
    /// CHUP_SERIAL so its own "which one is this TV?" question never fires: the answer
    /// was already given here.
    var tvSerial = ""

    /// Devices found by the last manual scan. Populated by Prep.scanDevices().
    @Published var foundDevices: [DeviceEntry] = []

    /// Pairing in progress for a specific address.
    @Published var pairingAddr: String? = nil
    @Published var pairCode = ""
    @Published var busy = false

    var launched = false

    init() {
        states = Array(repeating: .pending, count: WizardStep.all.count)
        states[0] = .active
    }

    var step: WizardStep { WizardStep.all[index] }
    var finished: Bool { states.allSatisfy { $0 == .done || $0 == .skipped } }

    // MARK: moving

    func advance() {
        if states[index] == .active { states[index] = .done }
        guard index + 1 < WizardStep.all.count else { return }
        // Clear stale scan when entering step 2 (discover) so it always starts fresh.
        if index + 1 == 1 {
            foundDevices = []
            pairingAddr = nil
            pairCode = ""
            note = ""
        }
        states[index + 1] = .active
        index += 1
    }

    func failCurrent() {
        states[index] = .failed
    }

    /// "Run again". The TV connected last time, so steps 1 to 3 stand and only the script
    /// starts over. If it never connected, go back to step 2 instead: that is where the list
    /// and the question live, and that is how they ended up running under "Install the apps".
    func rerun() {
        note = ""
        launched = true          // the caller starts the script, so onChange must not
        if deviceLine.isEmpty {
            for i in states.indices {
                states[i] = i < 1 ? .done : (i == 1 ? .active : .pending)
            }
            index = 1
        } else {
            for i in states.indices {
                if i == 2 {
                    states[i] = .skipped   // step 3 "Connect to the TV" — nothing to do
                } else {
                    states[i] = i < 3 ? .done : (i == 3 ? .active : .pending)
                }
            }
            index = 3
        }
    }

    // MARK: manual device scan + pairing (step 2)

    /// One manual scan for TVs: those offering Wireless debugging, and those with a plain adb
    /// daemon on port 5555. Called when the person presses Scan.
    func scanDevices(prep: Prep) {
        guard let adb = prep.adb else { return }
        foundDevices = []           // clear stale immediately so UI doesn't flicker old data
        pairingAddr = nil
        pairCode = ""
        note = "Scanning…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Prep.scanDevices(adb)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.foundDevices = found
                if found.isEmpty {
                    self.note = "No TVs found. Turn on Wireless debugging (leave its screen open), or check the box is on this Wi-Fi."
                } else {
                    let verb = found.contains { $0.pairing } ? "Pair" : "Connect"
                    self.note = "Found \(found.count) TV\(found.count == 1 ? "" : "s"). Press \(verb) next to yours."
                }
            }
        }
    }
    func startPairing(addr: String) {
        pairingAddr = addr
        pairCode = ""
        note = "On that TV: Wireless debugging ▸ Pair device with pairing code. Type the 6 digits here."
    }

    /// Submit the pairing code and connect. Called when the person presses Enter in the code field.
    func submitPairing(prep: Prep) {
        guard let adb = prep.adb, let addr = pairingAddr, pairCode.count >= 4 else { return }
        let code = pairCode
        pairingAddr = nil
        pairCode = ""
        busy = true
        note = "Pairing and connecting…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, msg) = Prep.pairAndConnect(adb, addr, code)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if ok {
                    self.foundDevices = []
                    let named = Prep.describe(adb, msg)  // msg is the serial here
                    self.tvSerial = msg
                    self.deviceLine = named.isEmpty ? msg : named
                    self.note = ""
                    // Connection is done. Skip step 3 (confirmation only) and go straight to
                    // step 4 where the script starts. shouldAutoStart fires at index == 3.
                    if self.states[self.index] == .active { self.states[self.index] = .done }
                    self.states[2] = .skipped   // step 3 "Connect to the TV" — nothing to do
                    self.index = 3
                    self.states[3] = .active
                } else {
                    self.pairingAddr = addr
                    self.note = msg.isEmpty ? "Pairing failed. Check the code on the TV and try again." : msg
                }
            }
        }
    }

    /// Connect to an already-paired TV, or to one exposing a plain adb daemon on port 5555.
    /// No pairing code needed for either.
    func connectOnly(addr: String, prep: Prep) {
        guard let adb = prep.adb else { return }
        busy = true
        note = "Connecting to \(addr)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (serial, problem) = Prep.attach(adb, addr)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if !serial.isEmpty {
                    self.foundDevices = []
                    let named = Prep.describe(adb, serial)
                    self.tvSerial = serial
                    self.deviceLine = named.isEmpty ? serial : named
                    self.note = ""
                    // Connection is done. Skip step 3 and go to step 4 where the script starts.
                    if self.states[self.index] == .active { self.states[self.index] = .done }
                    self.states[2] = .skipped
                    self.index = 3
                    self.states[3] = .active
                } else {
                    self.note = problem
                }
            }
        }
    }

    // MARK: the script's connection

    /// tv-setup.sh emits `::connected <serial>` the instant the box attaches. That is the only
    /// honest signal there is -- mDNS says what is advertising on the network, not what actually
    /// answered -- and it is what puts the rail on "Connect to the TV" while that is true.
    ///
    /// The script owns the whole of this part now: it finds the boxes, prints the list, asks
    /// which one is the TV, and attaches it. Nothing in here is allowed to connect on the
    /// person's behalf, because the question of which device to set up is theirs to answer.
    func connected(serial: String, prep: Prep) {
        let named = Prep.describe(prep.adb ?? "", serial)
        tvSerial = serial
        deviceLine = named.isEmpty ? serial : named
        // stdout and stderr are read on separate pipes, so the script's "3/7 Downloading apps"
        // can land first. Then the rail is already past this step and only the label under the
        // later ones was still worth recording.
        guard index <= 2 else { return }
        note = ""
        if states[index] == .active { states[index] = .done }
        for i in 0...2 where states[i] == .pending { states[i] = .done }
        states[2] = .skipped
        index = 3
        states[3] = .active
    }

    // MARK: mirroring the script

    /// tv-setup.sh owns steps 4–7. The app handles steps 1–3 entirely on its own now.
    /// The script starts when we reach step 4 (index 3) — "Install the apps".
    static func rail(forScriptStep n: Int) -> Int {
        switch n {
        case 1, 2: return 3      // adb + connect were app steps 1–3; script step 1–2 map to our step 4
        case 3, 4: return 3      // download + install -> "Install the apps"
        case 5: return 4         // RustDesk settings
        case 6: return 5         // Chup TV sign-in
        default: return 6        // finish + restart
        }
    }

    func observeScript(step n: Int) {
        guard n > 0 else { return }
        let target = Wizard.rail(forScriptStep: n)
        guard target >= index else { return }       // the script re-verifies steps we already did
        guard target != index else { return }       // it has reached the step we are already on

        if states[index] == .active { states[index] = .done }
        for i in 0..<target where states[i] == .pending { states[i] = .done }
        states[target] = .active
        index = target
    }

    /// The script exiting is the only honest signal that every script step is finished.
    func observeScriptExit(success: Bool) {
        guard index >= 3 else { return }
        if success {
            for i in states.indices where states[i] != .skipped { states[i] = .done }
        } else {
            states[index] = .failed
        }
    }

    /// True exactly once: step 3 (Connect to the TV) is done and the script may start.
    /// The script only runs the install/configure part (its steps 3–7), because the app
    /// already did adb, device selection and connection.
    func shouldAutoStart(runnerRunning: Bool) -> Bool {
        guard index == 3, !launched, !runnerRunning, !deviceLine.isEmpty else { return false }
        launched = true
        return true
    }
}
