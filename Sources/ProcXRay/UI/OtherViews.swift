import AppKit
import SwiftUI

/// Empty bottom-pane placeholder (same frame as real content so the split never jumps).
struct PanePlaceholder: View {
    let text: String
    var body: some View {
        Text(verbatim: text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Left Behind (processes whose responsible app has exited)

struct GhostsView: View {
    @Environment(Store.self) var store
    @State private var selection: pid_t?

    var body: some View {
        let ghosts = store.ghosts
        SplitPane(id: "ghosts") {
            List(selection: $selection) {
                if ghosts.isEmpty {
                    Text("Nothing left behind — every process's responsible app is still running.")
                        .foregroundStyle(.secondary)
                }
                ForEach(ghosts) { g in
                    SwiftUI.Section {
                        ForEach(g.survivors) { p in
                            HStack {
                                if let i = IconCache.icon(for: p) { Image(nsImage: i) }
                                Text(p.name)
                                Text(verbatim: "\(p.pid)").monospacedDigit().foregroundStyle(.secondary)
                                Text(verbatim: "started \(Fmt.age(p.start)) ago").foregroundStyle(.secondary)
                                Spacer()
                                Text(Fmt.bytes(p.footprint)).monospacedDigit()
                                Button("Terminate") { _ = store.send(SIGTERM, to: p.pid); store.refresh() }
                                    .controlSize(.small)
                            }
                            .tag(p.pid)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(g.name).bold()
                            Text(verbatim: "exited pid \(g.deadPid)").foregroundStyle(.secondary)
                            if let a = g.lsApp, !a.stateTags.isEmpty {
                                Text(a.stateTags.joined(separator: " ")).foregroundStyle(.red).font(.caption)
                            }
                            Spacer()
                            Text(verbatim: "\(g.survivors.count) still running").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } bottom: {
            if let pid = selection, let p = store.procs[pid] {
                InspectorView(proc: p)
            } else {
                PanePlaceholder(text: "Select a process")
            }
        }
        .navigationTitle("Left Behind")
        .navigationSubtitle("macOS keeps an app 'running in background' while these live")
    }
}

// MARK: - LaunchServices

struct AppsView: View {
    @Environment(Store.self) var store
    @State private var selection: LSApp.ID?
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\LSApp.index)]

    var body: some View {
        let apps = store.lsApps.filter {
            search.isEmpty || [$0.name, $0.bundleID ?? "", $0.bundlePath ?? "", $0.type ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted(using: sort)
        SplitPane(id: "apps", defaultFraction: 0.65) {
            Table(apps, selection: $selection, sortOrder: $sort) {
                TableColumn("#", value: \.index) { Text(verbatim: "\($0.index)").monospacedDigit() }.width(30)
                TableColumn("Name", value: \.name) { a in
                    Text(a.name).foregroundStyle(a.exited ? .red : .primary)
                }.width(min: 120, ideal: 180)
                TableColumn("PID") { a in Text(a.pid.map(String.init) ?? "").monospacedDigit() }.width(56)
                TableColumn("Type") { a in Text(a.type ?? "") }.width(min: 70, ideal: 100)
                TableColumn("Coalition") { a in Text(a.coalition.map(String.init) ?? "").monospacedDigit() }.width(64)
                TableColumn("Related PIDs") { a in
                    Text(a.relatedCoalitionPIDs.map(String.init).joined(separator: " ")).foregroundStyle(.orange)
                }.width(min: 60, ideal: 90)
                TableColumn("State") { a in Text(a.stateTags.joined(separator: " ")).foregroundStyle(.secondary) }.width(min: 80, ideal: 160)
                TableColumn("Bundle ID") { a in Text(a.bundleID ?? "").foregroundStyle(.secondary) }.width(min: 120, ideal: 220)
                TableColumn("Arch") { a in Text(a.arch ?? "") }.width(50)
            }
        } bottom: {
            if let id = selection, let a = store.lsApps.first(where: { $0.id == id }) {
                OutputPane(raw: a.raw, filterable: true) { f in
                    ScrollView { LSRecordContent(raw: a.raw, filter: f).padding(10) }
                }
            } else {
                PanePlaceholder(text: "Select an app to see its raw lsappinfo record")
            }
        }
        .searchable(text: $search, placement: .toolbar)
        .navigationTitle("LaunchServices Apps")
        .navigationSubtitle("lsappinfo list — \(store.lsApps.count) registered")
    }
}

// MARK: - Background Task Management

struct BackgroundItemsView: View {
    @Environment(Store.self) var store
    @State private var selection: BTMItem.ID?
    @State private var search = ""
    @State private var onlyEnabled = false

    var body: some View {
        let items = store.btm.filter { i in
            (!onlyEnabled || i.enabled) &&
            (search.isEmpty || [i.name, i.identifier, i.developer, i.teamID, i.executable, i.url, i.bundleID, i.type]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }
        if store.btm.isEmpty && !store.btmLoading {
            VStack(spacing: 10) {
                Image(systemName: store.helperState.isRunning ? "gearshape.2" : "lock.shield")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(verbatim: store.helperState.isRunning
                     ? "Background items are loaded on request."
                     : "The Background Task Management database is root-only.")
                Text(verbatim: store.helperState.isRunning
                     ? "The privileged helper reads it as root — no password needed."
                     : "Reading it runs `sfltool dumpbtm`, which asks for your admin password every time.")
                    .foregroundStyle(.secondary)
                Button(store.helperState.isRunning ? "Load Background Items (via root helper)" : "Load Background Items (asks for password)") { store.loadBTM() }
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Background Items")
        } else {
            btmTable(items)
        }
    }

    @ViewBuilder
    private func btmTable(_ items: [BTMItem]) -> some View {
        SplitPane(id: "btm", defaultFraction: 0.65) {
            Table(items, selection: $selection) {
                TableColumn("Name") { i in
                    HStack {
                        Circle().fill(i.enabled ? .green : .gray).frame(width: 7, height: 7)
                        Text(i.name)
                    }
                }.width(min: 140, ideal: 220)
                TableColumn("Type") { i in Text(i.type) }.width(min: 90, ideal: 140)
                TableColumn("Disposition") { i in Text(i.disposition).foregroundStyle(.secondary) }.width(min: 120, ideal: 220)
                TableColumn("Developer") { i in Text(i.developer) }.width(min: 90, ideal: 150)
                TableColumn("Team") { i in Text(i.teamID).monospaced() }.width(min: 70, ideal: 90)
                TableColumn("Target") { i in Text(i.executable.ifEmpty(i.url)).foregroundStyle(.secondary).truncationMode(.middle) }.width(min: 120, ideal: 260)
                TableColumn("Last use") { i in Text(i.lastUse) }.width(min: 90, ideal: 150)
                TableColumn("UID") { i in Text(i.uid) }.width(40)
            }
        } bottom: {
            if let id = selection, let i = store.btm.first(where: { $0.id == id }) {
                KV(rows: i.fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                   + (i.embedded.isEmpty ? [] : [("Embedded items", i.embedded.joined(separator: "\n"))]))
            } else {
                PanePlaceholder(text: "Select a background item")
            }
        }
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            Toggle("Enabled only", isOn: $onlyEnabled)
            Button { store.loadBTM() } label: { Label(store.helperState.isRunning ? "Reload" : "Reload (asks for password)", systemImage: "arrow.clockwise") }
                .disabled(store.btmLoading)
                .help(store.helperState.isRunning ? "Runs sfltool dumpbtm as root via the helper" : "Runs sfltool dumpbtm, which requires admin authorization")
            if store.btmLoading { ProgressView().controlSize(.small) }
        }
        .navigationTitle("Background Items")
        .navigationSubtitle("sfltool dumpbtm — \(store.btm.count) records, loaded on request only")
    }
}

// MARK: - launchd

struct LaunchdView: View {
    @Environment(Store.self) var store
    @State private var selection: LaunchdJob.ID?
    @State private var search = ""
    @State private var runningOnly = true
    @State private var detail = ""
    @State private var sort = [KeyPathComparator(\LaunchdJob.label)]

    var body: some View {
        let procs = store.procs
        let jobs = store.jobs.filter {
            (!runningOnly || $0.pid != nil) && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search))
        }.sorted(using: sort)
        SplitPane(id: "launchd", defaultFraction: 0.6) {
            Table(jobs, selection: $selection, sortOrder: $sort) {
                TableColumn("Label", value: \.label) { j in Text(j.label) }.width(min: 200, ideal: 360)
                TableColumn("PID") { j in Text(j.pid.map(String.init) ?? "—").monospacedDigit() }.width(60)
                TableColumn("Last exit", value: \.lastExit) { j in
                    Text(j.lastExit).foregroundStyle(j.lastExit == "0" || j.lastExit == "-" ? Color.secondary : Color.red)
                }.width(70)
                TableColumn("Process") { j in Text(j.pid.flatMap { procs[$0]?.path } ?? "").foregroundStyle(.secondary) }
            }
        } bottom: {
            if selection != nil {
                if detail == "loading…" { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { OutputPane(raw: detail, filterable: true) { f in KVTreeView(text: detail, filter: f) } }
            } else { PanePlaceholder(text: "Select a job to see launchctl print") }
        }
        .task(id: selection) {
            guard let label = selection else { return }
            detail = "loading…"
            detail = await Task.detached { Launchd.printJob(label) }.value
        }
        .searchable(text: $search, placement: .toolbar)
        .toolbar { Toggle("Running only", isOn: $runningOnly) }
        .navigationTitle("launchd Jobs")
        .navigationSubtitle("gui/\(getuid()) domain — \(store.jobs.count) jobs")
    }
}

// MARK: - CLI self-test (`ProcXRay --dump`) used to cross-check against ps / lsappinfo

enum SelfTest {
    @MainActor static func run() {
        let snap = Store.snapshot(prevCPU: [:], signCache: [:])
        let procs = snap.procs
        print("processes: \(procs.count)")
        print("team id: \(HelperConfig.teamID ?? "none")  requirement: \(HelperConfig.peerRequirement)")
        let hs = HelperClient.shared.probe()
        print("helper: \(hs.label)")
        if hs.isRunning {
            let t0 = Date()
            let priv = HelperClient.shared.allMetrics() ?? [:]
            let merged = Store.snapshot(prevCPU: [:], signCache: [:], priv: priv).procs
            print("helper metrics: \(priv.count) pids, \(priv.values.filter { $0.rss != nil }.count) with task info, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            print("merged readable task info: \(merged.values.filter(\.isInspectable).count) / \(merged.count) (via helper: \(merged.values.filter(\.viaHelper).count))")
            if let ld = merged[1] { print("launchd via helper: rss=\(ld.rss ?? 0) threads=\(ld.threads ?? -1)") }
            let a = HelperClient.shared.argsEnv(1)
            print("launchd argv via helper: \(a?.args ?? []) env=\(a?.env.count ?? -1) cwd=\(a?.cwd ?? "-")")
            let pi = HelperClient.shared.run(.launchctlProcinfo, pid: 1) ?? ""
            print("procinfo(1) lines: \(pi.split(separator: "\n").count)")
        }
        print("readable task info: \(procs.values.filter(\.isInspectable).count)")
        print("with responsible pid: \(procs.values.filter { $0.responsible != nil }.count)")
        print("with coalition: \(procs.values.filter { $0.coalition != nil }.count)")
        print("ls apps: \(snap.ls.count), exited: \(snap.ls.filter(\.exited).map(\.name))")
        print("ls apps with coalition id: \(snap.ls.filter { $0.coalition != nil }.count)")
        for a in snap.ls where !a.relatedCoalitionPIDs.isEmpty {
            print("ls \(a.name) pid \(a.pid ?? -1) coal \(a.coalition ?? 0) members \(a.coalitionPIDs) related \(a.relatedCoalitionIDs)/\(a.relatedCoalitionPIDs)")
        }
        print("launchd jobs: \(snap.jobs.count), running: \(snap.jobs.filter { $0.pid != nil }.count)")
        // Every grouping must place each process exactly once, with unique row ids.
        let store = Store(); store.procs = procs; store.lsApps = snap.ls
        for g in Grouping.allCases {
            let roots = store.nodes(grouping: g, filter: "", sort: [KeyPathComparator(\ProcNode.pidKey)])
            var ids: [Int] = [], pids: [pid_t] = []
            func walk(_ n: ProcNode) { ids.append(n.id); if let p = n.proc { pids.append(p.pid) }; n.children?.forEach(walk) }
            roots.forEach(walk)
            let ok = Set(ids).count == ids.count && pids.count == procs.count && Set(pids) == Set(procs.keys)
            print("grouping \(g.label): \(roots.count) roots, \(pids.count) procs, \(ids.count) rows — \(ok ? "ok" : "MISMATCH")")
            if g == .jetsam {
                for r in roots.filter({ ($0.children ?? []).contains { $0.proc == nil } })
                    .sorted(by: { ($0.children?.count ?? 0) > ($1.children?.count ?? 0) }).prefix(4) {
                    print("  \(r.title): \(r.subtitle); first: \(r.children!.filter { $0.proc == nil }.map(\.title).sorted().prefix(2))")
                }
            }
        }
        for g in Store.ghosts(procs: procs, lsApps: snap.ls) {
            print("left behind by \(g.name) (dead pid \(g.deadPid)): \(g.survivors.map { "\($0.name)(\($0.pid))" })")
        }
        let me = getpid()
        if let p = procs[me] {
            print("self: \(p.name) pid \(p.pid) ppid \(p.ppid) resp \(p.responsible ?? -1) coal \(p.coalition ?? 0) fp \(Fmt.bytes(p.footprint))")
            let s = CodeSign.inspect(pid: me, path: p.path)
            print("self sign: \(s.shortSigner) id=\(s.identifier ?? "-") flags=\(s.runtimeFlagNames)")
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pid"), i + 1 < args.count, let pid = pid_t(args[i + 1]), let p = procs[pid] {
            print("pid \(pid): name=\(p.name) ppid=\(p.ppid) resp=\(p.responsible ?? -1) coal=\(p.coalition ?? 0) user=\(p.user) rss=\(p.rss ?? 0) threads=\(p.threads ?? -1) sandbox=\(String(describing: p.sandboxed)) label=\(p.launchdLabel ?? "-")")
            let s = CodeSign.inspect(pid: pid, path: p.path)
            print("  sign: \(s.shortSigner) team=\(s.teamID ?? "-") id=\(s.identifier ?? "-") ents=\(s.entitlementKeys.count) status=\(s.runtimeFlagNames)")
            if let a = Native.argsEnv(pid) { print("  argv: \(a.args) env count: \(a.env.count)") }
            print("  cwd: \(Native.cwd(pid) ?? "-")")
        }
        // `sfltool dumpbtm` prompts for an admin password, so only run it when explicitly asked.
        if args.contains("--btm") {
            let btm = BTM.dump()
            print("btm records: \(btm.count), enabled: \(btm.filter(\.enabled).count)")
        }
    }
}
