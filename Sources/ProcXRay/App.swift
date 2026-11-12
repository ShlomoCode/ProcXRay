import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum Entry {
    static func main() {
        // Same binary serves as the root helper when launchd starts it with --helper.
        if CommandLine.arguments.contains("--helper") { HelperDaemon.run() }
        ProcXRayApp.main()
    }
}

struct ProcXRayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = Store()

    init() {
        if CommandLine.arguments.contains("--spawn-leftover") {
            // Test helper: reproduce "app quit but its helper kept running".
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["120"]
            try? p.run()
            print("spawned leftover sleep pid \(p.processIdentifier) from pid \(getpid())")
            exit(0)
        }
        if CommandLine.arguments.contains("--bench") {
            Bench.run()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--helper-call") {
            Bench.helperCall(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("ProcXRay") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 650)
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            InspectCommand()
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { store.refresh() }.keyboardShortcut("r")
                Button(store.paused ? "Resume Updates" : "Pause Updates") { store.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Process", id: ProcessWindow.id, for: ProcessRef.self) { $ref in
            if let ref { ProcessWindow(ref: ref).environment(store) }
        }
        .defaultSize(width: 900, height: 640)
        .commandsRemoved()   // no "New Process Window": these only open from a process row
    }
}

/// View ▸ Inspect Process (⌘I), as in Activity Monitor; acts on the selected row of the focused window.
struct InspectCommand: Commands {
    @FocusedValue(\.inspectProcess) private var inspect
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Inspect Process") { inspect?() }
                .keyboardShortcut("i")
                .disabled(inspect == nil)
            Divider()
        }
    }
}

struct InspectProcessKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var inspectProcess: (() -> Void)? {
        get { self[InspectProcessKey.self] }
        set { self[InspectProcessKey.self] = newValue }
    }
}

enum Section: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case ghosts = "Left Behind"
    case apps = "LaunchServices Apps"
    case background = "Background Items"
    case launchd = "launchd Jobs"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .processes: "cpu"
        case .ghosts: "figure.walk.departure"
        case .apps: "app.badge"
        case .background: "gearshape.2"
        case .launchd: "bolt.horizontal"
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) var store
    @State private var section: Section? = .processes

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                HStack {
                    Label(s.rawValue, systemImage: s.icon)
                    Spacer()
                    if s == .ghosts, store.ghostCount > 0 {
                        Text(verbatim: "\(store.ghostCount)").font(.caption).padding(.horizontal, 6)
                            .background(.orange.opacity(0.3), in: Capsule())
                    }
                }.tag(s)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    HelperBadge()
                    RefreshStats()
                }
                .font(.caption).foregroundStyle(.secondary).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch section ?? .processes {
            case .processes: ProcessesView()
            case .ghosts: GhostsView()
            case .apps: AppsView()
            case .background: BackgroundItemsView()
            case .launchd: LaunchdView()
            }
        }
    }
}

/// Per-refresh numbers, in their own view so that only this text re-renders on every tick.
struct RefreshStats: View {
    @Environment(Store.self) var store
    var body: some View {
        Text(verbatim: "\(store.procs.count) processes")
        Text(verbatim: "snapshot \(store.refreshMillis) ms")
    }
}

struct HelperBadge: View {
    @Environment(Store.self) var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(store.helperState.isRunning ? .green : .orange).frame(width: 7, height: 7)
                Text(verbatim: store.helperState.label).lineLimit(2)
            }
            switch store.helperState {
            case .notInstalled, .unreachable:
                Button("Install Privileged Helper…") { store.installHelper() }
                    .help("Registers a root daemon (SMAppService) for reading other users' processes. macOS asks you to approve it once in Login Items.")
            case .needsApproval:
                Button("Open Login Items to Approve") { HelperClient.shared.openLoginItems(); store.probeHelper() }
            case .running:
                Button("Uninstall Helper") { store.uninstallHelper() }
            case .notFound:
                EmptyView()
            }
            if let e = store.helperError { Text(verbatim: e).foregroundStyle(.red).lineLimit(3) }
        }
        .padding(.bottom, 4)
    }
}
