import SwiftUI

/// One entry point so the same binary is either the app or a headless driver:
///   chup-setup                 the Chup Setup window
///   chup-setup --run           run the setup, log to stdout, questions to stderr, answers on stdin
///   chup-setup --selftest      check the log/progress parsing and exit
@main
struct EntryPoint {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            exit(Headless.selfTest() ? 0 : 1)
        }
        if args.contains("--run") {
            Headless.run()
            dispatchMain()      // never returns; drains the Runner's main-queue callbacks
        }
        if args.contains("--wizard") {
            Headless.wizard()
        } else {
            ChupSetupApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var runner: Runner?

    /// Closing the window ends the run rather than leaving a script nobody can see.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-run must not orphan the script: it is the only thing that knows how to put
    /// the TV's stay-on setting back, and closing the pipes under it would kill it before it
    /// could. Stop it, wait, then finish quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runner = runner, runner.isRunning else { return .terminateNow }
        runner.onStoppedForQuit = { NSApp.reply(toApplicationShouldTerminate: true) }
        runner.beginShutdown()
        // Do not strand the person at a beach ball if the script refuses to go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ChupSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runner = Runner()

    var body: some Scene {
        Window("Chup TV Setup", id: "main") {
            ContentView()
                .environmentObject(runner)
                .onAppear { appDelegate.runner = runner }
        }
        .defaultSize(width: 880, height: 660)
    }
}
