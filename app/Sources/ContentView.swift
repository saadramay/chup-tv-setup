import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var runner: Runner
    @StateObject private var wizard = Wizard()
    @StateObject private var prep = Prep()

    @State private var answer = ""
    @State private var showLog = false
    @State private var booted = false
    @State private var zoomed: NSImage?
    @FocusState private var promptFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
            Divider()
            detail
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear(perform: boot)
        .onChange(of: runner.stepNumber) { n in
            wizard.observeScript(step: n)
        }
        .onChange(of: runner.connectedSerial) { serial in
            guard let serial else { return }
            wizard.connected(serial: serial, prep: prep)
        }
        .onChange(of: runner.outcome) { outcome in
            // Cleared when a run starts; only a real outcome means anything.
            guard let outcome else { return }
            wizard.observeScriptExit(success: isSuccess(outcome))
        }
        .onChange(of: wizard.index) { newIndex in
            if newIndex == 1 { wizard.scanDevices(prep: prep) }      // auto-scan on step 2
            if wizard.shouldAutoStart(runnerRunning: runner.isRunning) {
                runner.presetSerial = wizard.tvSerial
                runner.start()
            }
        }
        .onChange(of: runner.prompt?.id) { _ in
            answer = ""
            guard runner.prompt != nil else { return }
            showLog = false
            // Give SwiftUI a beat to put the field in the hierarchy before focusing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { promptFocused = true }
        }
        .overlay {
            // Readable at a glance only at full size; a 1080p TV screen shrunk into the pane
            // is not something anybody can follow. Click the thumbnail to open it.
            if let image = zoomed {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.82).ignoresSafeArea()
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(48)
                    Button {
                        zoomed = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .onTapGesture { zoomed = nil }
            }
        }
    }

    private func isSuccess(_ outcome: Outcome) -> Bool {
        if case .success = outcome { return true }
        return false
    }

    // MARK: starting

    private func boot() {
        guard !booted else { return }
        booted = true
        guard let script = Runner.bundledScript() else {
            wizard.note = "tv-setup.sh is missing from this copy of the app."
            return
        }
        // The app cannot drop a stale connection until it has adb, and only the script knows
        // how to fetch it. Step 1's instructions are on screen while this runs.
        prep.ensureAdb(script: script) { ok in
            guard ok, let adb = prep.adb else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                // Start every run from nothing. A connection left over from an earlier run reads
                // as attached while being half-dead — the port it was opened on is long gone —
                // so make this run find the TV and attach to it again rather than trust the list.
                Prep.clearConnection(adb)
            }
        }
    }

    // MARK: rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chup TV Setup")
                    .font(.title3.bold())
                Text("Seven steps. Everything except the first two runs itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(WizardStep.all.enumerated()), id: \.element.id) { i, step in
                        railRow(i: i, step: step)
                    }
                }
                .padding(.horizontal, 10)
            }

            if !prep.lastError.isEmpty {
                Text(prep.lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()
            options
        }
        .frame(width: 284)
        .background(Color.primary.opacity(0.03))
    }

    private func railRow(i: Int, step: WizardStep) -> some View {
        let state = wizard.states[i]
        let current = i == wizard.index
        return HStack(alignment: .top, spacing: 10) {
            statusDot(state, id: step.id, current: current)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout)
                    .fontWeight(current ? .semibold : .regular)
                    .foregroundStyle(state == .failed ? Color.red
                                     : current ? Color.primary : Color.secondary)
                if state == .skipped {
                    Text("Not needed this time")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(current ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func statusDot(_ state: StepState, id: Int, current: Bool) -> some View {
        ZStack {
            Circle()
                .fill(fill(for: state, current: current))
                .frame(width: 18, height: 18)
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            case .skipped:
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            case .active, .pending:
                // The number, not a spinner: these two are waiting on you, not on the app.
                Text("\(id)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(state == .active ? Color.white : Color.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .padding(.top, 1)
    }

    private func fill(for state: StepState, current: Bool) -> Color {
        switch state {
        case .done: return .green
        case .skipped: return .gray.opacity(0.6)
        case .failed: return .red
        case .active: return .accentColor
        case .pending: return current ? .accentColor.opacity(0.5) : Color.secondary.opacity(0.25)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Restart the TV when setup finishes",
                   isOn: $runner.restartAfter)
            Toggle("Use the latest script from GitHub", isOn: $runner.fetchLatest)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        .disabled(runner.isRunning)
        .padding(12)
    }

    // MARK: detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepBody
            if runner.prompt != nil { promptBox }
            if let outcome = runner.outcome { outcomeRow(outcome) }
            logBox
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var stepBody: some View {
        let step = wizard.step
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Step \(step.id) of 7")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if step.kind == .script {
                    Text("runs by itself")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(step.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            if !wizard.deviceLine.isEmpty && wizard.index >= 2 {
                Label("Connected: \(wizard.deviceLine)", systemImage: "tv")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !step.how.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(step.how.enumerated()), id: \.offset) { n, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(n + 1).")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(line)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
            }

            if let image = shot(step) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 230)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
                    .padding(.vertical, 2)
                    .onTapGesture { zoomed = image }
                    .overlay(alignment: .bottomTrailing) {
                        Label("Click for full size", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .padding(7)
                            .allowsHitTesting(false)
                    }
            }

            if !step.expect.isEmpty {
                Text(step.expect)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !wizard.note.isEmpty {
                Text(wizard.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls(for: step)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func controls(for step: WizardStep) -> some View {
        switch step.kind {
        case .manual:
            HStack(spacing: 10) {
                Button("I've done that") {
                    wizard.advance()
                }
                .keyboardShortcut(.defaultAction)
                Text("Now do step 2 — the script starts looking for TVs the moment you do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .discover:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("Scan") { wizard.scanDevices(prep: prep) }
                        .disabled(wizard.foundDevices.isEmpty == false || prep.working)
                    if !wizard.foundDevices.isEmpty {
                        Button("Scan again") { wizard.scanDevices(prep: prep) }
                    }
                    Spacer(minLength: 12)
                }
                if !wizard.foundDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TVs found on this network:")
                            .font(.callout.bold())
                        ForEach(wizard.foundDevices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: device.pairing ? "iphone.gen3.radiowaves.left.and.right" : "tv.fill")
                                    .foregroundStyle(device.pairing ? .orange : .accentColor)
                                Text(device.addr)
                                    .font(.system(.callout, design: .monospaced))
                                Text(device.pairing ? "Pairing screen open" : "Already paired")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                if wizard.pairingAddr == nil || wizard.pairingAddr == device.addr {
                                    Button(device.pairing ? "Pair" : "Connect") {
                                        if device.pairing {
                                            wizard.startPairing(addr: device.addr)
                                        } else {
                                            // Already paired — just connect
                                            wizard.connectOnly(addr: device.addr, prep: prep)
                                        }
                                    }
                                    .keyboardShortcut(wizard.pairingAddr == device.addr ? .defaultAction : nil)
                                    .disabled(wizard.pairingAddr != nil && wizard.pairingAddr != device.addr)
                                }
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                if let addr = wizard.pairingAddr {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing with \(addr)")
                            .font(.callout.bold())
                        HStack(spacing: 8) {
                            TextField("6-digit code from TV", text: $wizard.pairCode)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onSubmit { wizard.submitPairing(prep: prep) }
                            Button("Connect") { wizard.submitPairing(prep: prep) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(wizard.pairCode.count < 4)
                            if wizard.pairCode.count >= 4 && wizard.busy {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

        case .connect:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(wizard.deviceLine.isEmpty ? "Connected." : "Connected to \(wizard.deviceLine).")
                    .font(.callout)
                Spacer(minLength: 12)
            }

        case .script:
            if !runner.isRunning && runner.outcome == nil && wizard.index < 6 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: prompt

    private var promptBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let prompt = runner.prompt {
                    Text(prompt.question)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        // Plain text even for passwords: the person typing must be able to see
                        // what they type on an unfamiliar machine. Secrecy lives in the log --
                        // Runner.submit never writes a secure answer to it.
                        TextField(prompt.secure ? "Type here" : "Type your answer, then press Enter", text: $answer)
                            .textFieldStyle(.roundedBorder)
                            .focused($promptFocused)
                            .onSubmit { send() }
                        Button("Send", action: send)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    if prompt.secure {
                        Text("Shown in plain text so you can check it, but never written to the log. Plain keyboard characters, at least 8 characters where a password is asked for.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func outcomeRow(_ outcome: Outcome) -> some View {
        HStack(spacing: 8) {
            switch outcome {
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: log

    private var logBox: some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "Nothing yet." : runner.log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0.86, green: 0.92, blue: 0.86))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                        .padding(8)
                        .id("bottom")
                }
                .frame(minHeight: 140, maxHeight: 260)
                .background(Color.black.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: runner.log) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Activity log")
                    .font(.callout)
                if runner.isRunning {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button("Copy log") { runner.copyLog() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            if runner.isRunning {
                Button("Cancel", role: .destructive) { runner.cancel() }
                Spacer()
                Text("Working — the TV needs no input right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let outcome = runner.outcome {
                if case .success = outcome {
                    Label("Setup complete. The TV can be unplugged, moved and powered back up.",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Run again") { reset() }
            } else {
                Spacer()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func reset() {
        wizard.rerun()
        runner.presetSerial = wizard.tvSerial
        runner.start()
    }

    private func send() {
        let value = answer
        answer = ""
        runner.submit(value)
    }

    // MARK: screenshots

    /// Captured from a real box with `adb shell screencap`, cropped to the half of the frame
    /// that has something in it, and shipped in Resources. A step without one still builds and
    /// still shows its written instructions.
    private func shot(_ step: WizardStep) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "tv-step\(step.id)", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
