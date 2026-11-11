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
            // Fixed-height header: a missing icon or path must not shift the tab strip below it.
            HStack(spacing: 6) {
                Group {
                    if let img = IconCache.icon(for: proc) { Image(nsImage: img) } else { Image(systemName: "terminal") }
                }
                .frame(width: 16, height: 16)
                Text(proc.name).font(.headline).lineLimit(1)
                Text(verbatim: "pid \(proc.pid)").foregroundStyle(.secondary).monospacedDigit()
                Text(proc.path ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .padding(.horizontal, 10).padding(.top, 4)
            InspectorTabStrip(selection: $tab)
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(proc: proc)
                case .lineage: LineageTab(proc: proc)
                case .signature: SignatureTab(proc: proc)
                case .entitlements:
                    let xml = store.signInfo(for: proc)?.entitlementsXML
                    OutputPane(raw: xml ?? "No entitlements (or not yet loaded).", filterable: true) { f in
                        EntitlementsView(xml: xml, filter: f)
                    }
                case .args: ArgsTab(proc: proc)
                case .files:
                    toolTab(.lsof, auto: true, title: "lsof -n -P -p \(proc.pid)",
                            parse: LsofParser.parse, isEmpty: \.isEmpty) { LsofView(entries: $0, filter: $1) }
                case .memory:
                    toolTab(.vmmap, auto: false, title: "vmmap --summary \(proc.pid)",
                            parse: VmmapParser.parse, isEmpty: \.isEmpty) { VmmapView(s: $0, filter: $1) }
                case .sample:
                    toolTab(.sample, auto: false, title: "sample \(proc.pid) 1 (all thread stacks for 1s)",
                            parse: SampleParser.parse, isEmpty: \.threads.isEmpty) { SampleView(report: $0, filter: $1) }
                case .logs:
                    let pid = proc.pid
                    CommandTab(key: "log\(proc.key)", auto: false,
                               title: "/usr/bin/log show --last 10m — events from pid \(pid) or mentioning it",
                               command: {
                                   // Full path on purpose: zsh has a `log` builtin that silently shadows /usr/bin/log.
                                   Shell.run("/usr/bin/log", ["show", "--last", "10m", "--style", "compact", "--info",
                                       "--predicate", "processID == \(pid) OR eventMessage CONTAINS \"\(pid)\""])
                               },
                               parse: LogParser.parse, isEmpty: \.isEmpty) { LogView(entries: $0, filter: $1) }
                case .launch: LaunchTab(proc: proc)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// lsof / vmmap / sample need root (or task_for_pid rights) for most processes: route them through
    /// the helper whenever it's running; otherwise run them as the user and explain failures.
    private func toolTab<P, V: View>(_ tool: HelperTool, auto: Bool, title: String,
                                     parse: @escaping @Sendable (String) -> P, isEmpty: @escaping (P) -> Bool,
                                     @ViewBuilder visual: @escaping (P, String) -> V) -> some View {
        let viaHelper = store.helperState.isRunning
        let pid = proc.pid
        let platform = store.signInfo(for: proc)?.isPlatform == true
        return CommandTab(key: "\(tool)\(proc.key)\(viaHelper)", auto: auto,
                          title: title + (viaHelper ? "   [as root via helper]" : "   [as \(NSUserName())]"),
                          command: {
            var out: String
            if viaHelper {
                out = HelperClient.shared.run(tool, pid: pid) ?? "helper did not answer"
            } else {
                // argv refuses pid 0 (kernel_task): it isn't a user-space task these tools can attach to.
                guard let (path, args) = tool.argv(pid: pid) else {
                    return "\(tool) can't inspect pid \(pid) (kernel_task is not a user-space process)."
                }
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
        }, parse: parse, isEmpty: isEmpty, visual: visual)
    }
}

/// Leading-anchored tab strip. Each tab is sized to its own label (no weight change on selection,
/// which would resize it), and the strip scrolls horizontally when the pane is too narrow instead of
/// overflowing and getting re-centred — the overflow is what made the old segmented control jump.
struct InspectorTabStrip: View {
    @Binding var selection: InspectorTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { t in
                    let on = t == selection
                    Button { selection = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 34)
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
        let jetMembers = p.jetsamCoalition.map { c in store.procs.values.filter { $0.jetsamCoalition == c }.count } ?? 0
        var rows: [(String, String)] = [
            ("Path", p.path ?? "— (\(p.comm))"),
            ("Working dir", cwd ?? "—"),
            ("Parent", "\(parent?.name ?? "?") (\(p.ppid))"),
            ("Responsible", resp),
            ("Coalition", p.coalition.map { "resource \($0) (\(coalMembers) member(s)) · jetsam \(p.jetsamCoalition.map(String.init) ?? "—") (\(jetMembers) member(s))" } ?? "—"),
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
        // Jetsam-mates outside the resource coalition: typically the host app and its extensions.
        let jet = proc.jetsamCoalition.map { j in
            store.procs.values.filter { $0.jetsamCoalition == j && $0.pid != proc.pid && $0.coalition != proc.coalition }
                .sorted { $0.pid < $1.pid }
        } ?? []
        List {
            SwiftUI.Section("Parent chain (ppid → launchd)") { ForEach(ancestors) { row($0) } }
            SwiftUI.Section("Children (\(children.count))") { ForEach(children) { row($0) } }
            SwiftUI.Section("Processes this one is responsible for (\(attributed.count))") { ForEach(attributed) { row($0) } }
            SwiftUI.Section("Same resource coalition (\(coal.count))") { ForEach(coal) { row($0) } }
            SwiftUI.Section("Same jetsam coalition, other resource coalitions (\(jet.count))") { ForEach(jet) { row($0) } }
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
                OutputPane(raw: "exec: \(info.execPath)\n\n── argv (\(info.args.count)) ──\n"
                         + info.args.enumerated().map { "[\($0)] \($1)" }.joined(separator: "\n")
                         + "\n\n── environment (\(info.env.count)) ──\n" + info.env.sorted().joined(separator: "\n"),
                           filterable: true) { f in
                    ArgsEnvView(info: info, filter: f)
                }
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

struct CommandTab<Parsed, Visual: View>: View {
    let key: String
    let auto: Bool
    let title: String
    let command: @Sendable () -> String
    let parse: @Sendable (String) -> Parsed
    let isEmpty: (Parsed) -> Bool
    @ViewBuilder let visual: (Parsed, String) -> Visual
    @State private var output: String?
    @State private var parsed: Parsed?
    @State private var generation = 0
    @State private var running = false
    @State private var filter = ""
    @AppStorage("showRawOutput") private var showRaw = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RawToggle(showRaw: $showRaw)
                Text(title).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField(showRaw ? "filter lines" : "filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(output == nil ? "Run" : "Re-run") { run() }.disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            .padding(6)
            Divider()
            if let output {
                if showRaw {
                    MonoText(text: filterLines(output, filter))
                } else if let parsed, !isEmpty(parsed) {
                    visual(parsed, filter).id(generation)   // fresh view state (expansion, chips) per run
                } else if parsed != nil {
                    UnparsedNote(raw: output)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Press Run to collect this data.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(running ? 0 : 1)
            }
        }
        .task(id: key) {
            output = nil
            parsed = nil
            if auto { run() }
        }
    }

    private func run() {
        running = true
        let cmd = command, parse = parse
        Task {
            let (out, p) = await Task.detached { () -> (String, Parsed) in
                let o = cmd()
                return (o, parse(o))
            }.value
            output = out
            parsed = p
            generation += 1
            running = false
        }
    }
}

struct LaunchTab: View {
    @EnvironmentObject var store: Store
    let proc: ProcInfo
    @State private var ls: String?
    @State private var job: (title: String, text: String)?
    @State private var procinfo: (title: String, text: String)?
    @State private var loading = true

    private var raw: String {
        var s = ""
        if let ls { s += "── LaunchServices (lsappinfo) ──\n\(ls)\n\n" }
        else { s += "── LaunchServices ──\nnot registered as an app with LaunchServices\n\n" }
        if let job { s += "── \(job.title) ──\n\(job.text)\n" }
        if let procinfo { s += "\n── \(procinfo.title) ──\n\(procinfo.text)" }
        return s
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OutputPane(raw: raw, filterable: true) { f in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            section("LaunchServices", "app.badge") {
                                if let ls { LSRecordContent(raw: ls, filter: f) }
                                else { note("Not registered as an app with LaunchServices.") }
                            }
                            if let job {
                                section(job.title, "gearshape.2") {
                                    let nodes = LaunchctlParser.parse(job.text)
                                    if nodes.count > 1 { KVTreeContent(nodes: nodes, filter: f) } else { note(job.text) }
                                }
                            }
                            if let procinfo {
                                section(procinfo.title, "person.badge.shield.checkmark") {
                                    let nodes = LaunchctlParser.parse(procinfo.text)
                                    if nodes.count > 1 { KVTreeContent(nodes: nodes, filter: f) } else { note(procinfo.text) }
                                }
                            }
                        }
                        .padding(10)
                    }
                }
            }
        }
        .task(id: proc.key) {
            loading = true
            let label = proc.launchdLabel
            let lsRaw = store.lsApps.first { $0.pid == proc.pid }?.raw
            let pid = proc.pid
            let helper = store.helperState.isRunning
            let (j, p) = await Task.detached { () -> ((String, String), (String, String)) in
                let j = label.map { ("launchctl print \($0)", Launchd.printJob($0)) }
                    ?? ("launchd", "pid \(pid) is not the main process of a launchd job in your domain.")
                let p = helper
                    ? ("launchctl procinfo \(pid) (as root via helper)", HelperClient.shared.run(.launchctlProcinfo, pid: pid) ?? "helper did not answer")
                    : ("launchctl procinfo", "`launchctl procinfo \(pid)` shows full launchd attribution — install the privileged helper to see it.")
                return (j, p)
            }.value
            ls = lsRaw
            job = (j.0, j.1)
            procinfo = (p.0, p.1)
            loading = false
        }
    }

    private func section<C: View>(_ title: String, _ icon: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.title3.weight(.semibold))
            c()
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
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
