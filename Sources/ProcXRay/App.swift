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
    @StateObject private var store = Store()

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
        if CommandLine.arguments.contains("--dump") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("ProcXRay") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 650)
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { store.refresh() }.keyboardShortcut("r")
                Button(store.paused ? "Resume Updates" : "Pause Updates") { store.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
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
    @EnvironmentObject var store: Store
    @State private var section: Section? = .processes

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                HStack {
                    Label(s.rawValue, systemImage: s.icon)
                    Spacer()
                    if s == .ghosts, !store.ghosts.isEmpty {
                        Text(verbatim: "\(store.ghosts.count)").font(.caption).padding(.horizontal, 6)
                            .background(.orange.opacity(0.3), in: Capsule())
                    }
                }.tag(s)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    HelperBadge()
                    Text(verbatim: "\(store.procs.count) processes")
                    Text(verbatim: "snapshot \(store.refreshMillis) ms")
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

struct HelperBadge: View {
    @EnvironmentObject var store: Store

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
