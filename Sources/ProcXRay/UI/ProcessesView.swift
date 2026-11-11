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
    @EnvironmentObject var store: Store
    @AppStorage("grouping") private var grouping: Grouping = .parent
    @State private var search = ""
    @State private var selection: ProcNode.ID?
    @State private var sort = [KeyPathComparator(\ProcNode.pidKey)]
    @State private var pendingSignal: (pid_t, Int32, String)?

    var body: some View {
        let nodes = store.nodes(grouping: grouping, filter: search, sort: sort)
        SplitPane(id: "processes") {
            ProcessTable(store: store, nodes: nodes, selection: $selection, sort: $sort, grouping: grouping) { pid, sig, label in
                pendingSignal = (pid, sig, label)
            }
        } bottom: {
            Group {
                if let id = selection, id >= 0, let p = store.procs[pid_t(id)] {
                    InspectorView(proc: p)
                } else if let id = selection, id < 0 {
                    Text("Group row — select a process inside it.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Select a process").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "name, pid, path, team, bundle, label…")
        .toolbar {
            ToolbarItemGroup {
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

/// Table cells can be laid out in hosting views that don't inherit environment objects, so nothing
/// inside this table reads @EnvironmentObject — the store and data are passed explicitly.
struct ProcessTable: View {
    @ObservedObject var store: Store
    let nodes: [ProcNode]
    @Binding var selection: ProcNode.ID?
    @Binding var sort: [KeyPathComparator<ProcNode>]
    let grouping: Grouping
    let onSignal: (pid_t, Int32, String) -> Void

    var body: some View {
        let procs = store.procs
        Table(nodes, children: \ProcNode.children, selection: $selection, sortOrder: $sort) {
            Group {
                TableColumn("Name", value: \ProcNode.nameKey) { n in NameCell(node: n, orphan: isOrphan(n)) }
                    .width(min: 180, ideal: 260)
                TableColumn("PID", value: \ProcNode.pidKey) { n in Text(n.proc.map { String($0.pid) } ?? "").monospacedDigit() }
                    .width(min: 44, ideal: 56)
                TableColumn("CPU %", value: \ProcNode.cpuKey) { n in Text(Fmt.pct(n.proc?.cpuPercent ?? (n.proc == nil ? n.cpuKey : nil))).monospacedDigit() }
                    .width(min: 44, ideal: 52)
                TableColumn("Memory", value: \ProcNode.memKey) { n in Text(n.proc == nil ? Fmt.bytes(n.memKey) : Fmt.bytes(n.proc?.footprint)).monospacedDigit() }
                    .width(min: 60, ideal: 76)
                TableColumn("Thr", value: \ProcNode.threadsKey) { n in Text(n.proc?.threads.map(String.init) ?? "").monospacedDigit() }
                    .width(min: 30, ideal: 36)
                TableColumn("User", value: \ProcNode.userKey) { n in Text(n.proc?.user ?? "") }
                    .width(min: 50, ideal: 70)
            }
            Group {
                TableColumn("Responsible", value: \ProcNode.respKey) { n in RespCell(proc: n.proc, procs: procs) }
                    .width(min: 80, ideal: 130)
                TableColumn("Res. coal.", value: \ProcNode.coalKey) { n in Text(n.proc?.coalition.map(String.init) ?? "").monospacedDigit() }
                    .width(min: 50, ideal: 64)
                TableColumn("Jetsam", value: \ProcNode.jetsamKey) { n in Text(n.proc?.jetsamCoalition.map(String.init) ?? "").monospacedDigit() }
                    .width(min: 50, ideal: 64)
                TableColumn("Signer", value: \ProcNode.signerKey) { n in Text(n.proc?.signer ?? "").foregroundStyle(n.proc?.signer == "unsigned" ? .red : .primary) }
                    .width(min: 70, ideal: 110)
                TableColumn("Disk I/O", value: \ProcNode.diskKey) { n in Text(n.proc.map { Fmt.bytes(($0.diskRead ?? 0) + ($0.diskWrite ?? 0)) } ?? "").monospacedDigit() }
                    .width(min: 56, ideal: 70)
                TableColumn("Started", value: \ProcNode.startKey) { n in Text(n.proc.map { Fmt.age($0.start) } ?? "") }
                    .width(min: 50, ideal: 70)
                TableColumn("Context") { n in Text(context(n)).foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 120, ideal: 300)
            }
        }
        // A new sort rebuilds the table: diffing it as row moves tears down every realized cell view
        // one by one, which freezes the UI for seconds on a reversed sort.
        .id(sort)
        .contextMenu(forSelectionType: ProcNode.ID.self) { ids in
            if let id = ids.first, id >= 0, let p = store.procs[pid_t(id)] {
                Button("Terminate (SIGTERM)") { onSignal(p.pid, SIGTERM, "SIGTERM") }
                Button("Kill (SIGKILL)") { onSignal(p.pid, SIGKILL, "SIGKILL") }
                Button("Suspend (SIGSTOP)") { onSignal(p.pid, SIGSTOP, "SIGSTOP") }
                Button("Resume (SIGCONT)") { _ = store.send(SIGCONT, to: p.pid) }
                Divider()
                if let path = p.path {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Copy Path") { copy(path) }
                }
                Button("Copy PID") { copy("\(p.pid)") }
                if let r = p.responsible, r != p.pid, store.procs[r] != nil {
                    Button("Select Responsible (\(r))") { selection = Int(r) }
                }
                if p.ppid > 1 { Button("Select Parent (\(p.ppid))") { selection = Int(p.ppid) } }
            }
        }
    }

    private func isOrphan(_ n: ProcNode) -> Bool {
        guard let p = n.proc, let r = p.responsible, r != p.pid else { return false }
        return store.procs[r] == nil
    }

    private func context(_ n: ProcNode) -> String {
        guard let p = n.proc else { return n.subtitle }
        var parts: [String] = []
        if let l = p.launchdLabel { parts.append("launchd: \(l)") }
        if let a = p.lsAppName { parts.append("LS: \(a)") }
        if !p.lsTags.isEmpty { parts.append(p.lsTags.joined(separator: " ")) }
        if parts.isEmpty, let path = p.path { parts.append(path) }
        return parts.joined(separator: " · ")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct NameCell: View {
    let node: ProcNode
    let orphan: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let p = node.proc {
                if let img = IconCache.icon(for: p) { Image(nsImage: img) } else { Image(systemName: "terminal").frame(width: 16) }
                Text(node.title).foregroundStyle(color(p)).lineLimit(1)
                Badges(proc: p, orphan: orphan)
            } else {
                Image(systemName: node.isGhost ? "exclamationmark.triangle.fill" : "square.stack.3d.up")
                    .foregroundStyle(node.isGhost ? .orange : .secondary)
                Text(node.title).bold().foregroundStyle(node.isGhost ? .orange : .primary).lineLimit(1)
            }
        }
    }

    private func color(_ p: ProcInfo) -> Color {
        if p.isZombie { return .secondary }
        if orphan { return .orange }
        if !p.isInspectable { return .secondary }
        return .primary
    }
}

struct Badges: View {
    let proc: ProcInfo
    let orphan: Bool
    var body: some View {
        HStack(spacing: 2) {
            if orphan { tag("LEFT", .orange) }
            if proc.isZombie { tag("ZOMBIE", .gray) }
            if proc.isTranslated { tag("ROSETTA", .purple) }
            if proc.sandboxed == true { tag("SBX", .teal) }
            if proc.lsTags.contains(where: { $0.hasPrefix("exited") }) { tag("EXITED", .red) }
        }
    }
    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 8, weight: .bold)).padding(.horizontal, 3).padding(.vertical, 1)
            .background(c.opacity(0.25), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(c)
    }
}

struct RespCell: View {
    let proc: ProcInfo?
    let procs: [pid_t: ProcInfo]
    var body: some View {
        if let p = proc, let r = p.responsible {
            if r == p.pid {
                Text("self").foregroundStyle(.secondary)
            } else if let rp = procs[r] {
                Text(verbatim: "\(rp.name) (\(r))").lineLimit(1)
            } else {
                Text(verbatim: "† gone (\(r))").foregroundStyle(.orange)
            }
        } else {
            Text("")
        }
    }
}
