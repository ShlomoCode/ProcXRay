import AppKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case general = "General"
    case lineage = "Lineage"
    case signature = "Signature"
    case entitlements = "Entitlements"
    case args = "Args & Env"
    case files = "Files & Sockets"
    case memory = "Memory Map"
    case sample = "Sample"
    case logs = "Logs"
    case launch = "launchd / LS"
    var id: String { rawValue }
}

struct InspectorView: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo
    @AppStorage("inspectorTab") private var tab: InspectorTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let img = IconCache.icon(for: proc) { Image(nsImage: img) }
                Text(proc.name).font(.headline)
                Text(verbatim: "pid \(proc.pid)").foregroundStyle(.secondary).monospacedDigit()
                if let path = proc.path {
                    Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 6)
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(proc: proc)
                case .lineage: LineageTab(proc: proc)
                case .signature: SignatureTab(proc: proc)
                case .entitlements:
                    MonoText(text: store.signInfo(for: proc)?.entitlementsXML ?? "No entitlements (or not yet loaded).")
                case .args: ArgsTab(proc: proc)
                case .files: toolTab(.lsof, auto: true, title: "lsof -n -P -p \(proc.pid)")
                case .memory: toolTab(.vmmap, auto: false, title: "vmmap --summary \(proc.pid)")
                case .sample: toolTab(.sample, auto: false, title: "sample \(proc.pid) 1 (all thread stacks for 1s)")
                case .logs: CommandTab(key: "log\(proc.key)", auto: false,
                                       title: "/usr/bin/log show --last 10m — events from pid \(proc.pid) or mentioning it") {
                    // Full path on purpose: zsh has a `log` builtin that silently shadows /usr/bin/log.
                    Shell.run("/usr/bin/log", ["show", "--last", "10m", "--style", "compact", "--info",
                        "--predicate", "processID == \(proc.pid) OR eventMessage CONTAINS \"\(proc.pid)\""])
                }
                case .launch: LaunchTab(proc: proc)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// lsof / vmmap / sample need root (or task_for_pid rights) for most processes: route them through
    /// the helper whenever it's running; otherwise run them as the user and explain failures.
    private func toolTab(_ tool: HelperTool, auto: Bool, title: String) -> some View {
        let viaHelper = store.helperState.isRunning
        let pid = proc.pid
        let platform = store.signInfo(for: proc)?.isPlatform == true
        return CommandTab(key: "\(tool)\(proc.key)\(viaHelper)", auto: auto,
                          title: title + (viaHelper ? "   [as root via helper]" : "   [as \(NSUserName())]")) {
            var out: String
            if viaHelper {
                out = HelperClient.shared.run(tool, pid: pid) ?? "helper did not answer"
            } else {
                let (path, args) = tool.argv(pid: pid)!
                out = Shell.run(path, args)
            }
            let failed = out.isEmpty || out.contains("not permitted") || out.contains("Unable to") || out.contains("failed")
            if failed && tool != .lsof {
                out += viaHelper && platform
                    ? "\n\n— SIP prevents inspecting Apple platform binaries' memory, even as root."
                    : (viaHelper ? "" : "\n\n— Needs task_for_pid rights. Install the privileged helper (sidebar) to run this as root.")
            } else if tool == .lsof && !viaHelper && proc.uid != getuid() {
                out += "\n\n— Running as \(NSUserName()): another user's open files aren't visible. Install the helper for full output."
            }
            return out
        }
    }
}

// MARK: - Key/value grid

struct KV: View {
    let rows: [(String, String)]
    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(r.1).textSelection(.enabled).font(.system(.body, design: .monospaced))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo
    @State private var cwd: String?

    var body: some View {
        let p = proc
        let parent = store.procs[p.ppid]
        let resp: String = {
            guard let r = p.responsible else { return "unknown" }
            if r == p.pid { return "self (\(r))" }
            if let rp = store.procs[r] { return "\(rp.name) (\(r))" }
            let name = store.lsApps.first { $0.pid == r }?.name
            return "† \(name ?? "exited process") (\(r)) — no longer running"
        }()
        let coalMembers = p.coalition.map { c in store.procs.values.filter { $0.coalition == c }.count } ?? 0
        var rows: [(String, String)] = [
            ("Path", p.path ?? "— (\(p.comm))"),
            ("Working dir", cwd ?? "—"),
            ("Parent", "\(parent?.name ?? "?") (\(p.ppid))"),
            ("Responsible", resp),
            ("Coalition", p.coalition.map { "resource \($0) · jetsam \(p.jetsamCoalition ?? 0) · \(coalMembers) member(s)" } ?? "—"),
            ("Process group", "\(p.pgid)"),
            ("User", "\(p.user) (uid \(p.uid))"),
            ("Started", "\(Fmt.date.string(from: p.start))  (\(Fmt.age(p.start)) ago)"),
            ("State", stateText(p)),
            ("Sandboxed", p.sandboxed.map { $0 ? "yes" : "no" } ?? "unknown"),
            ("Rosetta", p.isTranslated ? "yes (x86_64 translated)" : "no"),
        ]
        if p.isInspectable {
            rows += [
                ("Footprint", Fmt.bytes(p.footprint)),
                ("Resident", Fmt.bytes(p.rss)),
                ("Virtual", Fmt.bytes(p.virt)),
                ("CPU time", p.cpuNanos.map { String(format: "%.2f s", Double($0) / 1e9) } ?? "—"),
                ("CPU now", p.cpuPercent.map { String(format: "%.1f %%", $0) } ?? "—"),
                ("Threads", p.threads.map(String.init) ?? "—"),
                ("Disk read / written", "\(Fmt.bytes(p.diskRead)) / \(Fmt.bytes(p.diskWrite))"),
                ("Billed energy", p.energyNJ.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—"),
                ("Idle wakeups", p.wakeups.map(String.init) ?? "—"),
            ]
        } else {
            rows.append(("Task info", "not accessible (owned by \(p.user)) — install the privileged helper to read it"))
        }
        if p.viaHelper { rows.append(("Source", "task metrics read as root via the privileged helper")) }
        if let l = p.launchdLabel { rows.append(("launchd label", l)) }
        if let a = p.lsAppName { rows.append(("LaunchServices", "\(a) \(p.lsTags.joined(separator: " "))")) }
        return KV(rows: rows).task(id: p.key) {
            let pid = p.pid
            let helper = store.helperState.isRunning
            cwd = await Task.detached { () -> String? in
                if let c = Native.cwd(pid) { return c }
                return helper ? HelperClient.shared.argsEnv(pid)?.cwd : nil
            }.value
        }
    }

    private func stateText(_ p: ProcInfo) -> String {
        switch p.stat {
        case 1: "idle (being created)"
        case 2: "runnable"
        case 3: "sleeping"
        case 4: "stopped"
        case 5: "zombie"
        default: "\(p.stat)"
        }
    }
}

// MARK: - Lineage

struct LineageTab: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo

    var body: some View {
        let ancestors: [ProcInfo] = {
            var out: [ProcInfo] = []
            var cur = proc
            var seen: Set<pid_t> = [proc.pid]
            while let par = store.procs[cur.ppid], !seen.contains(par.pid) {
                out.append(par); seen.insert(par.pid); cur = par
            }
            return out
        }()
        let children = store.procs.values.filter { $0.ppid == proc.pid && $0.pid != proc.pid }.sorted { $0.pid < $1.pid }
        let attributed = store.procs.values.filter { $0.responsible == proc.pid && $0.pid != proc.pid }.sorted { $0.pid < $1.pid }
        let coal = proc.coalition.map { c in store.procs.values.filter { $0.coalition == c && $0.pid != proc.pid }.sorted { $0.pid < $1.pid } } ?? []
        List {
            SwiftUI.Section("Parent chain (ppid → launchd)") { ForEach(ancestors) { row($0) } }
            SwiftUI.Section("Children (\(children.count))") { ForEach(children) { row($0) } }
            SwiftUI.Section("Processes this one is responsible for (\(attributed.count))") { ForEach(attributed) { row($0) } }
            SwiftUI.Section("Same coalition (\(coal.count))") { ForEach(coal) { row($0) } }
        }
    }

    private func row(_ p: ProcInfo) -> some View {
        HStack {
            if let i = IconCache.icon(for: p) { Image(nsImage: i) }
            Text(p.name)
            Text(verbatim: "\(p.pid)").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Text(p.path ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Signature

struct SignatureTab: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo
    var body: some View {
        if let s = store.signInfo(for: proc) {
            KV(rows: [
                ("Signer", s.shortSigner),
                ("Identifier", s.identifier ?? "—"),
                ("Team ID", s.teamID ?? "—"),
                ("Authority", s.authority.isEmpty ? "—" : s.authority.joined(separator: "\n")),
                ("Valid now", s.valid.map { $0 ? "yes" : "NO" } ?? "unknown"),
                ("CDHash", s.cdHash ?? "—"),
                ("Static flags", s.staticFlagNames.joined(separator: " ").ifEmpty("none")),
                ("Runtime status", s.runtimeStatus.map { String(format: "0x%08x  ", $0) + s.runtimeFlagNames.joined(separator: " ") } ?? "—"),
                ("Entitlements", s.entitlementKeys.isEmpty ? "none" : s.entitlementKeys.joined(separator: "\n")),
                ("Requirement", s.designatedRequirement ?? "—"),
                ("Error", s.error ?? "—"),
            ])
        } else {
            ProgressView("Reading code signature…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - Args & env

struct ArgsTab: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo
    @State private var info: Native.ArgsEnv?
    @State private var loaded = false

    var body: some View {
        Group {
            if let info {
                MonoText(text: "exec: \(info.execPath)\n\n── argv (\(info.args.count)) ──\n"
                         + info.args.enumerated().map { "[\($0)] \($1)" }.joined(separator: "\n")
                         + "\n\n── environment (\(info.env.count)) ──\n" + info.env.sorted().joined(separator: "\n"))
            } else if loaded {
                Text("Arguments not readable (other user's process, or it has exited).").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
            }
        }
        .task(id: proc.key) {
            let pid = proc.pid
            let helper = store.helperState.isRunning
            info = await Task.detached { () -> Native.ArgsEnv? in
                if let a = Native.argsEnv(pid) { return a }
                guard helper, let r = HelperClient.shared.argsEnv(pid) else { return nil }
                return Native.ArgsEnv(execPath: r.execPath, args: r.args, env: r.env)
            }.value
            loaded = true
        }
    }
}

// MARK: - Shell-backed tabs

struct CommandTab: View {
    let key: String
    let auto: Bool
    let title: String
    let command: @Sendable () -> String
    @State private var output: String?
    @State private var running = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                TextField("filter lines", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(output == nil ? "Run" : "Re-run") { run() }.disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            .padding(6)
            Divider()
            if let output {
                MonoText(text: filter.isEmpty ? output : output.split(separator: "\n")
                    .filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n"))
            } else {
                Spacer()
            }
        }
        .task(id: key) {
            output = nil
            if auto { run() }
        }
    }

    private func run() {
        running = true
        let cmd = command
        Task {
            let out = await Task.detached { cmd() }.value
            output = out
            running = false
        }
    }
}

struct LaunchTab: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo
    @State private var text = ""

    var body: some View {
        MonoText(text: text).task(id: proc.key) {
            text = "loading…"
            let label = proc.launchdLabel
            let ls = store.lsApps.first { $0.pid == proc.pid }
            let pid = proc.pid
            let helper = store.helperState.isRunning
            text = await Task.detached {
                var s = ""
                if let ls { s += "── LaunchServices (lsappinfo) ──\n\(ls.raw)\n\n" }
                else { s += "── LaunchServices ──\nnot registered as an app with LaunchServices\n\n" }
                if let label {
                    s += "── launchctl print \(label) ──\n" + Launchd.printJob(label)
                } else {
                    s += "── launchd ──\npid \(pid) is not the main process of a launchd job in your domain.\n"
                }
                if helper {
                    s += "\n── launchctl procinfo \(pid) (as root via helper) ──\n"
                    s += HelperClient.shared.run(.launchctlProcinfo, pid: pid) ?? "helper did not answer"
                } else {
                    s += "\n(`launchctl procinfo \(pid)` shows full launchd attribution — install the privileged helper to see it.)\n"
                }
                return s
            }.value
        }
    }
}

/// Fast, selectable monospaced text (SwiftUI Text chokes on 10k-line outputs).
struct MonoText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isAutomaticLinkDetectionEnabled = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        if tv.string != text {
            tv.string = text
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = .labelColor
        }
    }
}
