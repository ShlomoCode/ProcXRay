import AppKit
import SwiftUI

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for p: ProcInfo) -> NSImage? {
        guard let key = p.bundlePath ?? p.path else { return nil }
        if let i = cache[key] { return i }
        let i = NSWorkspace.shared.icon(forFile: key)
        i.size = NSSize(width: 16, height: 16)
        cache[key] = i
        return i
    }
}

struct ProcessesView: View {
    @Environment(Store.self) var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("grouping") private var grouping: Grouping = .parent
    @State private var search = ""
    @State private var selection: ProcNode.ID?
    @State private var sort = [KeyPathComparator(\ProcNode.pidKey)]
    @State private var pendingSignal: (pid_t, Int32, String)?

    // This body must not read per-refresh data (store.procs, nodes): then it would re-render every tick,
    // and each re-render pushes SwiftUI's environment through every cell view of the outline. The outline
    // observes the store itself. The selected process is looked up only when an action runs.
    private var hasProcessSelected: Bool { (selection ?? -1) >= 0 }
    private func inspectSelected() {
        if let id = selection, id >= 0, let p = store.procs[pid_t(id)] { inspect(p) }
    }

    private func inspect(_ p: ProcInfo) { openWindow(id: ProcessWindow.id, value: ProcessRef(p)) }

    var body: some View {
        ProcessOutline(store: store, grouping: grouping, filter: search,
                       selection: $selection, sort: $sort,
                       onOpen: { p in inspect(p) },
                       onSignal: { pid, sig, label in pendingSignal = (pid, sig, label) })
            // A grouping switch re-parents nearly every row; start from a fresh outline (all expanded).
            .id(grouping)
        .focusedSceneValue(\.inspectProcess, hasProcessSelected ? { inspectSelected() } : nil)
        .searchable(text: $search, placement: .toolbar, prompt: "name, pid, path, team, bundle, label…")
        .toolbar {
            ToolbarItemGroup {
                Button { inspectSelected() } label: { Label("Inspect", systemImage: "info.circle") }
                    .help("Inspect the selected process (⌘I)")
                    .disabled(!hasProcessSelected)
                Menu {
                    Picker("Group", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(grouping.label, systemImage: "list.bullet.indent").labelStyle(.titleAndIcon)
                }
                .fixedSize()
                Button { store.paused.toggle() } label: {
                    Label(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play.fill" : "pause.fill")
                }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .navigationTitle("Processes")
        .confirmationDialog(pendingSignal.map { "Send \($0.2) to pid \($0.0)?" } ?? "",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
            Button(pendingSignal?.2 ?? "Send", role: .destructive) {
                if let (pid, sig, _) = pendingSignal {
                    if let err = store.send(sig, to: pid) { NSSound.beep(); print("signal failed: \(err)") }
                    store.refresh()
                }
                pendingSignal = nil
            }
        }
    }
}

/// Identifies one process instance for a property window: a pid alone could be reused by a later process.
struct ProcessRef: Codable, Hashable {
    var pid: pid_t
    var start: TimeInterval
    init(_ p: ProcInfo) { pid = p.pid; start = p.start.timeIntervalSince1970 }
}

/// Property sheet for one process, opened by double-clicking (or Return on) a row.
struct ProcessWindow: View {
    static let id = "process"
    @Environment(Store.self) var store
    let ref: ProcessRef
    @State private var lastSeen: ProcInfo?

    var body: some View {
        let live = store.procs[ref.pid].flatMap { $0.start.timeIntervalSince1970 == ref.start ? $0 : nil }
        Group {
            if let p = live ?? lastSeen {
                VStack(spacing: 0) {
                    if live == nil {
                        Text("This process has exited. Showing its last known state.")
                            .font(.callout).frame(maxWidth: .infinity).padding(6)
                            .background(.orange.opacity(0.2))
                    }
                    InspectorView(proc: p)
                }
                .navigationTitle(Text(verbatim: "\(p.name) (\(p.pid))"))
            } else {
                Text(verbatim: "pid \(ref.pid) is not running").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: live, initial: true) { _, p in if let p { lastSeen = p } }
        .frame(minWidth: 640, minHeight: 420)
    }
}
