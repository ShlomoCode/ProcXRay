import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

struct ProcInfo: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }
    var pid: pid_t
    var ppid: pid_t
    var pgid: pid_t
    var uid: uid_t
    var user: String
    var comm: String
    var path: String?
    var start: Date
    var stat: Int8
    var pflags: Int32

    var responsible: pid_t?
    var coalition: UInt64?
    var jetsamCoalition: UInt64?
    var sandboxed: Bool?

    var rss: UInt64?
    var footprint: UInt64?
    var virt: UInt64?
    var threads: Int32?
    var cpuNanos: UInt64?
    var cpuPercent: Double?
    var diskRead: UInt64?
    var diskWrite: UInt64?
    var energyNJ: UInt64?
    var wakeups: UInt64?

    // joined from other sources
    var launchdLabel: String?
    var lsAppName: String?
    var lsTags: [String] = []
    var signer: String?
    var signID: String?
    var viaHelper = false              // metrics came from the root helper

    var key: String { "\(pid):\(start.timeIntervalSince1970)" }
    var name: String {
        if let p = path { return (p as NSString).lastPathComponent }
        return comm
    }
    var isZombie: Bool { stat == 5 }
    var isTranslated: Bool { pflags & 0x20000 != 0 }   // P_TRANSLATED (Rosetta)
    var isInspectable: Bool { rss != nil }
    var respIsOther: Bool { responsible != nil && responsible != pid }

    /// Bundle (.app) that owns the executable, if any.
    var bundlePath: String? {
        guard let p = path, let r = p.range(of: ".app/", options: .backwards) else { return nil }
        return String(p[..<r.lowerBound]) + ".app"
    }
}

struct Ghost: Identifiable, Sendable {
    var id: pid_t { deadPid }
    var deadPid: pid_t
    var name: String
    var lsApp: LSApp?
    var survivors: [ProcInfo]
}

enum Grouping: String, CaseIterable, Identifiable {
    case parent = "Parent tree"
    case responsible = "Responsible tree"
    case coalition = "Coalition"   // raw value kept stable: it's persisted in @AppStorage("grouping")
    case jetsam = "Jetsam coalition"
    case flat = "Flat"
    var id: String { rawValue }
    var label: String { self == .coalition ? "Resource coalition" : rawValue }
}

/// A row in the process table: a real process, or a synthetic group (dead responsible app / coalition).
struct ProcNode: Identifiable, Sendable {
    var id: Int
    var proc: ProcInfo?
    var title: String
    var subtitle: String = ""
    var isGhost = false
    var children: [ProcNode]?

    var nameKey: String { title.lowercased() }
    var pidKey: Int { proc.map { Int($0.pid) } ?? Int(Int32.max) }
    var cpuKey: Double { proc?.cpuPercent ?? children?.reduce(0) { $0 + $1.cpuKey } ?? 0 }
    var memKey: UInt64 { proc?.footprint ?? children?.reduce(0) { $0 + $1.memKey } ?? 0 }
    var userKey: String { proc?.user ?? "" }
    var signerKey: String { proc?.signer ?? "" }
    var threadsKey: Int32 { proc?.threads ?? 0 }
    var respKey: Int { proc?.responsible.map(Int.init) ?? 0 }
    var coalKey: UInt64 { proc?.coalition ?? 0 }
    var jetsamKey: UInt64 { proc?.jetsamCoalition ?? 0 }
    var startKey: Date { proc?.start ?? .distantPast }
    var diskKey: UInt64 { (proc?.diskRead ?? 0) + (proc?.diskWrite ?? 0) }

    func matches(_ q: String) -> Bool {
        if title.localizedCaseInsensitiveContains(q) || subtitle.localizedCaseInsensitiveContains(q) { return true }
        guard let p = proc else { return false }
        if String(p.pid) == q { return true }
        return [p.path, p.signer, p.signID, p.launchdLabel, p.lsAppName, p.user]
            .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

@MainActor
@Observable
final class Store {
    var procs: [pid_t: ProcInfo] = [:] { didSet { dataGen &+= 1 } }
    var lsApps: [LSApp] = [] { didSet { dataGen &+= 1 } }
    var jobs: [LaunchdJob] = []
    var btm: [BTMItem] = []
    var btmLoading = false
    var paused = false
    var interval: Double = 2
    var lastRefresh = Date()
    var refreshMillis = 0

    /// Bumped whenever an input of nodes() changes, so the table's tree is only rebuilt when needed.
    @ObservationIgnored private var dataGen = 0
    /// Bumps each time nodes() actually rebuilds, so views can skip work when it returned the cached tree.
    @ObservationIgnored private(set) var nodesVersion = 0
    @ObservationIgnored private var nodesCache: (gen: Int, grouping: Grouping, filter: String, sort: [KeyPathComparator<ProcNode>], nodes: [ProcNode])?

    private(set) var signCache: [String: SignInfo] = [:]
    @ObservationIgnored private var prevCPU: [String: (UInt64, UInt64)] = [:]   // key -> (cpuNanos, wall uptime nanos)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var signing = false
    var helperState: HelperClient.State = .notInstalled
    var helperError: String?
    @ObservationIgnored private var lastProbe = Date.distantPast

    init() {
        probeHelper()
        refresh()
        schedule()
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification,
        ]
        visibilityObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Let a closing/miniaturizing window finish changing state before reading it.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.visibilityChanged() } }
            }
        }
    }

    /// Whether any of our windows is on screen. Hidden, minimized, closed, fully covered, on another
    /// Space or behind a locked screen all count as off screen; nothing is refreshed then, so the app
    /// costs ~0 while it sits in the background.
    @ObservationIgnored private(set) var onScreen = true
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []

    private func visibilityChanged() {
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        guard visible != onScreen else { return }
        onScreen = visible
        if ProcessInfo.processInfo.environment["PROCXRAY_DEBUG"] != nil { NSLog("ProcXRay on screen: %d", visible ? 1 : 0) }
        if visible {
            // A CPU % averaged over the whole off-screen stretch would be misleading: start a fresh
            // baseline and take the second sample shortly after so the column fills in quickly.
            prevCPU = [:]
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh(full: false) }
        }
        schedule()
    }

    func probeHelper() {
        lastProbe = Date()
        Task.detached {
            let s = HelperClient.shared.probe()
            await MainActor.run { self.helperState = s }
        }
    }

    func installHelper() {
        do {
            try HelperClient.shared.register()
            helperError = nil
        } catch {
            // register() throws "Operation not permitted" when the daemon is registered but awaiting the
            // user's approval in Login Items — that's the normal first-run path, not an error.
            if HelperClient.shared.service.status == .requiresApproval {
                helperError = nil
                HelperClient.shared.openLoginItems()
            } else {
                helperError = error.localizedDescription
            }
        }
        probeHelper()
    }

    func uninstallHelper() {
        do { try HelperClient.shared.unregister(); helperError = nil } catch { helperError = error.localizedDescription }
        probeHelper()
    }

    func schedule() {
        timer?.invalidate()
        timer = nil
        guard onScreen else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                self.refresh(full: false)
            }
        }
        t.tolerance = interval * 0.2   // lets the system coalesce our wakeups with others
        RunLoop.main.add(t, forMode: .default)   // as before: no refreshes mid-scroll or while a menu is open
        timer = t
    }

    /// LaunchServices and launchd state changes rarely and costs two subprocess spawns to read
    /// (`lsappinfo` alone is ~25 ms of CPU plus work in launchservicesd), so timer ticks re-read it only
    /// every `slowEvery` ticks. Manual refreshes and coming back on screen always read everything.
    private static let slowEvery = 5
    @ObservationIgnored private var ticksSinceSlow = 0

    func refresh(full: Bool = true) {
        guard !refreshing else { return }
        refreshing = true
        let prev = prevCPU
        let cache = signCache
        let useHelper = helperState.isRunning
        let readSlow = full || ticksSinceSlow + 1 >= Self.slowEvery || lsApps.isEmpty
        ticksSinceSlow = readSlow ? 0 : ticksSinceSlow + 1
        let ls = readSlow ? nil : lsApps
        let jobs = readSlow ? nil : self.jobs
        if Date().timeIntervalSince(lastProbe) > 10 { probeHelper() }
        Task.detached(priority: .userInitiated) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let priv = useHelper ? HelperClient.shared.allMetrics() : nil
            let snap = Self.snapshot(prevCPU: prev, signCache: cache, priv: priv, ls: ls, jobs: jobs)
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            await MainActor.run {
                self.procs = snap.procs
                if readSlow {
                    self.lsApps = snap.ls
                    self.jobs = snap.jobs
                }
                self.prevCPU = snap.cpu
                self.updateGhostCount()
                self.lastRefresh = Date()
                self.refreshMillis = ms
                self.refreshing = false
                self.fillSignatures()
            }
        }
    }

    /// Code-signing lookups are the slow part; do the missing ones in the background and merge.
    private func fillSignatures() {
        guard !signing else { return }
        let missing = procs.values.filter { signCache[$0.key] == nil }.map { ($0.key, $0.pid, $0.path) }
        guard !missing.isEmpty else { return }
        signing = true
        Task.detached(priority: .utility) {
            var acc: [String: SignInfo] = [:]
            for (k, pid, path) in missing { acc[k] = CodeSign.inspect(pid: pid, path: path) }
            let found = acc
            await MainActor.run {
                self.signCache.merge(found) { a, _ in a }
                let live = Set(self.procs.values.map(\.key))
                self.signCache = self.signCache.filter { live.contains($0.key) }
                // snapshot() already applied every older cache entry; patch only the processes that were
                // just inspected, on a local copy, and publish once. Writing self.procs[pid] in a loop
                // copied the whole dictionary per write and invalidated the table ~700 times.
                var procs = self.procs
                var changed = false
                for (pid, p) in procs {
                    guard let s = found[p.key], p.signer != s.shortSigner || p.signID != s.identifier else { continue }
                    procs[pid]!.signer = s.shortSigner; procs[pid]!.signID = s.identifier
                    changed = true
                }
                if changed { self.procs = procs }
                self.signing = false
            }
        }
    }

    func loadBTM() {
        guard !btmLoading else { return }
        btmLoading = true
        let useHelper = helperState.isRunning
        Task.detached {
            // As root the helper's sfltool doesn't need to prompt; without it, sfltool asks for a password.
            let items = useHelper ? BTM.parse(HelperClient.shared.run(.btmDump) ?? "") : BTM.dump()
            await MainActor.run { self.btm = items; self.btmLoading = false }
        }
    }

    func signInfo(for p: ProcInfo) -> SignInfo? { signCache[p.key] }

    // MARK: Snapshot (off main thread)

    struct Snapshot: Sendable {
        var procs: [pid_t: ProcInfo]
        var ls: [LSApp]
        var jobs: [LaunchdJob]
        var cpu: [String: (UInt64, UInt64)]
    }

    /// `ls` / `jobs`: reuse these instead of re-reading LaunchServices / launchd (nil = read them now).
    nonisolated static func snapshot(prevCPU: [String: (UInt64, UInt64)], signCache: [String: SignInfo],
                                     priv: [Int32: PrivMetrics]? = nil,
                                     ls: [LSApp]? = nil, jobs: [LaunchdJob]? = nil) -> Snapshot {
        let ls = ls ?? LSAppInfo.list()
        let jobs = jobs ?? Launchd.list()
        var labelByPid: [pid_t: String] = [:]
        for j in jobs { if let p = j.pid { labelByPid[p] = j.label } }
        var lsByPid: [pid_t: LSApp] = [:]
        for a in ls { if let p = a.pid { lsByPid[p] = a } }

        let now = DispatchTime.now().uptimeNanoseconds
        var users: [uid_t: String] = [:]
        var out: [pid_t: ProcInfo] = [:]
        var cpu: [String: (UInt64, UInt64)] = [:]

        for k in Native.allProcesses() where k.pid >= 0 {
            let user = users[k.uid] ?? { let u = Native.userName(k.uid); users[k.uid] = u; return u }()
            var p = ProcInfo(pid: k.pid, ppid: k.ppid, pgid: k.pgid, uid: k.uid, user: user, comm: k.comm,
                             path: Native.path(k.pid), start: k.start, stat: k.stat, pflags: k.flags)
            p.responsible = Native.responsible(k.pid)
            if let c = Native.coalition(k.pid) { p.coalition = c.0; p.jetsamCoalition = c.1 }
            if let ti = Native.taskInfo(k.pid) {
                p.rss = ti.pti_resident_size
                p.virt = ti.pti_virtual_size
                p.threads = ti.pti_threadnum
                p.cpuNanos = Native.machToNanos(ti.pti_total_user &+ ti.pti_total_system)
            }
            if let ru = Native.rusage(k.pid) {
                p.footprint = ru.ri_phys_footprint
                p.diskRead = ru.ri_diskio_bytesread
                p.diskWrite = ru.ri_diskio_byteswritten
                p.energyNJ = ru.ri_billed_energy
                p.wakeups = ru.ri_pkg_idle_wkups &+ ru.ri_interrupt_wkups
                if p.cpuNanos == nil { p.cpuNanos = Native.machToNanos(ru.ri_user_time &+ ru.ri_system_time) }
            }
            if p.rss == nil, let m = priv?[k.pid] {
                p.rss = m.rss; p.virt = m.virt; p.threads = m.threads; p.cpuNanos = m.cpuNanos
                p.footprint = m.footprint; p.diskRead = m.diskRead; p.diskWrite = m.diskWrite
                p.energyNJ = m.energyNJ; p.wakeups = m.wakeups
                if p.responsible == nil { p.responsible = m.responsible }
                p.viaHelper = m.rss != nil || m.footprint != nil
            }
            if let c = p.cpuNanos {
                if let (pc, pw) = prevCPU[p.key], now > pw, c >= pc {
                    p.cpuPercent = Double(c - pc) / Double(now - pw) * 100
                }
                cpu[p.key] = (c, now)
            }
            p.launchdLabel = labelByPid[k.pid]
            if let a = lsByPid[k.pid] { p.lsAppName = a.name; p.lsTags = a.stateTags }
            if let s = signCache[p.key] { p.signer = s.shortSigner; p.signID = s.identifier }
            out[k.pid] = p
        }
        // sandbox check is cheap but noisy for zombies; do it last
        for (pid, var p) in out where !p.isZombie {
            p.sandboxed = Native.sandboxed(pid) ?? priv?[pid]?.sandboxed
            out[pid] = p
        }
        return Snapshot(procs: out, ls: ls, jobs: jobs, cpu: cpu)
    }

    // MARK: Derived views

    /// Processes whose responsible process is gone — e.g. helpers an app left behind when it quit.
    var ghosts: [Ghost] { Self.ghosts(procs: procs, lsApps: lsApps) }

    /// For the sidebar badge: a stored value that is only written when it changes, so the sidebar
    /// doesn't re-render on every refresh.
    private(set) var ghostCount = 0
    private func updateGhostCount() {
        let n = ghosts.count
        if n != ghostCount { ghostCount = n }
    }

    /// Two signals: (1) responsible pid points at a dead process; (2) LaunchServices marks an app
    /// `exited-with-subordinates` — survivors share its coalition. lsappinfo's `coalition:` is the
    /// *jetsam* coalition id, so match against both ids.
    nonisolated static func ghosts(procs: [pid_t: ProcInfo], lsApps: [LSApp]) -> [Ghost] {
        var byDead: [pid_t: [ProcInfo]] = [:]
        for p in procs.values {
            if let r = p.responsible, r != p.pid, procs[r] == nil { byDead[r, default: []].append(p) }
        }
        let lsByPid = Dictionary(lsApps.compactMap { a in a.pid.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var out = byDead.map { dead, ps in
            let ls = lsByPid[dead]
            return Ghost(deadPid: dead, name: ls?.name ?? "unknown (pid \(dead))", lsApp: ls,
                         survivors: ps.sorted { $0.pid < $1.pid })
        }
        // LaunchServices entries marked exited-with-subordinates whose survivors we can find by coalition.
        for a in lsApps where a.exited {
            guard let pid = a.pid, byDead[pid] == nil else { continue }
            let listed = Set(a.coalitionPIDs + a.relatedCoalitionPIDs)
            let members = procs.values.filter { p in
                listed.contains(p.pid) || (a.coalition != nil && (p.coalition == a.coalition || p.jetsamCoalition == a.coalition))
            }
            out.append(Ghost(deadPid: pid, name: a.name, lsApp: a, survivors: members.sorted { $0.pid < $1.pid }))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func nodes(grouping: Grouping, filter: String, sort: [KeyPathComparator<ProcNode>]) -> [ProcNode] {
        if let c = nodesCache, c.gen == dataGen, c.grouping == grouping, c.filter == filter, c.sort == sort { return c.nodes }
        let out = buildNodes(grouping: grouping, filter: filter, sort: sort)
        nodesCache = (dataGen, grouping, filter, sort, out)
        nodesVersion &+= 1
        return out
    }

    private func buildNodes(grouping: Grouping, filter: String, sort: [KeyPathComparator<ProcNode>]) -> [ProcNode] {
        let all = Array(procs.values)
        var roots: [ProcNode]
        switch grouping {
        case .flat:
            roots = all.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) }
        case .parent:
            // launchd (1) and kernel_task (0) parent nearly everything; their children are the useful top level.
            roots = tree(all) { p in p.ppid > 1 && p.ppid != p.pid && self.procs[p.ppid] != nil ? Int(p.ppid) : nil }
        case .responsible:
            let lsByPid = Dictionary(lsApps.compactMap { a in a.pid.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
            var ghostIDs: [pid_t: Int] = [:]
            roots = tree(all) { p in
                guard let r = p.responsible, r != p.pid else { return nil }
                if self.procs[r] != nil { return Int(r) }
                ghostIDs[r] = -Int(r) - 1
                return -Int(r) - 1
            }
            // tree() put orphans-of-ghosts under synthetic ids; materialize those groups.
            var extra: [ProcNode] = []
            let byParent = Dictionary(grouping: roots.filter { $0.id < 0 }, by: \.id)
            roots.removeAll { $0.id < 0 }
            for (dead, gid) in ghostIDs {
                let kids = byParent[gid]?.flatMap { $0.children ?? [] } ?? []
                let name = lsByPid[dead]?.name ?? "?"
                extra.append(ProcNode(id: gid, proc: nil, title: "† \(name) — exited pid \(dead)",
                                      subtitle: "responsible process is gone", isGhost: true, children: kids))
            }
            roots += extra
        case .coalition:
            let groups = Dictionary(grouping: all) { $0.coalition ?? 0 }
            let lsByCoal = Dictionary(lsApps.compactMap { a in a.coalition.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
            roots = groups.map { coal, members in
                let leader = members.first { $0.responsible == $0.pid } ?? members.min { $0.pid < $1.pid }!
                let title = (lsByCoal[coal] ?? members.lazy.compactMap { $0.jetsamCoalition.flatMap { lsByCoal[$0] } }.first)?.name ?? leader.name
                return ProcNode(id: Self.groupID(coal, sub: false), proc: nil,
                                title: "\(title)  [coalition \(coal)]", subtitle: "\(members.count) processes",
                                children: members.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) })
            }
        case .jetsam:
            // One jetsam coalition can hold several resource coalitions (a host plus each of its app
            // extensions); the reverse doesn't occur. Nest resource coalitions when there's more than one.
            let groups = Dictionary(grouping: all) { $0.jetsamCoalition ?? 0 }
            let lsByCoal = Dictionary(lsApps.compactMap { a in a.coalition.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
            func leader(_ ps: [ProcInfo]) -> ProcInfo { ps.first { $0.responsible == $0.pid } ?? ps.min { $0.pid < $1.pid }! }
            func leaves(_ ps: [ProcInfo]) -> [ProcNode] { ps.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) } }
            roots = groups.map { jet, members in
                let byRes = Dictionary(grouping: members) { $0.coalition ?? 0 }
                // The host's resource coalition is created before its extensions', so the lowest id leads.
                let host = byRes.keys.min()!
                let title = lsByCoal[jet]?.name ?? leader(byRes[host]!).name
                let children: [ProcNode] = byRes.count == 1 ? leaves(members) : byRes.map { res, ps in
                    ProcNode(id: Self.groupID(res, sub: true), proc: nil,
                             title: "\(leader(ps).name)  [resource \(res)]", subtitle: "\(ps.count) processes",
                             children: leaves(ps))
                }
                let sub = byRes.count == 1 ? "\(members.count) processes"
                                           : "\(members.count) processes in \(byRes.count) resource coalitions"
                return ProcNode(id: Self.groupID(jet, sub: false), proc: nil,
                                title: "\(title)  [jetsam \(jet)]", subtitle: sub, children: children)
            }
        }
        if !filter.isEmpty { roots = prune(roots, filter) }
        return sorted(roots, sort)
    }

    /// Row id for a synthetic coalition group. Below every ghost id (-pid - 1); nested resource
    /// subgroups get odd offsets so they can't collide with a top-level group of the same id.
    private static func groupID(_ coal: UInt64, sub: Bool) -> Int { -10_000_000 - 2 * Int(coal) - (sub ? 1 : 0) }

    /// Build a forest using `parentOf`; unknown parents (negative ids) become temporary placeholder roots.
    private func tree(_ all: [ProcInfo], parentOf: (ProcInfo) -> Int?) -> [ProcNode] {
        var kids: [Int: [ProcInfo]] = [:]
        var roots: [ProcInfo] = []
        var placeholders: [Int: [ProcInfo]] = [:]
        for p in all {
            if let par = parentOf(p) {
                if par < 0 { placeholders[par, default: []].append(p) } else { kids[par, default: []].append(p) }
            } else { roots.append(p) }
        }
        func build(_ p: ProcInfo, depth: Int) -> ProcNode {
            let c = depth < 64 ? (kids[Int(p.pid)] ?? []).map { build($0, depth: depth + 1) } : []
            return ProcNode(id: Int(p.pid), proc: p, title: p.name, children: c.isEmpty ? nil : c)
        }
        var out = roots.map { build($0, depth: 0) }
        for (gid, ps) in placeholders {
            out.append(ProcNode(id: gid, proc: nil, title: "", children: ps.map { build($0, depth: 1) }))
        }
        return out
    }

    private func prune(_ nodes: [ProcNode], _ q: String) -> [ProcNode] {
        nodes.compactMap { n in
            if n.matches(q) { return n }
            guard let c = n.children else { return nil }
            let kept = prune(c, q)
            if kept.isEmpty { return nil }
            var m = n; m.children = kept; return m
        }
    }

    /// Ties are broken by row id. Without that, rows that tie (every group row has the same pidKey)
    /// kept Dictionary iteration order, which reshuffles whenever a process comes or goes; the table then
    /// saw hundreds of moved rows per refresh and spent seconds rebuilding and re-measuring row views.
    private func sorted(_ nodes: [ProcNode], _ sort: [KeyPathComparator<ProcNode>]) -> [ProcNode] {
        nodes.sorted { a, b in
            for c in sort {
                switch c.compare(a, b) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.id < b.id
        }.map { n in
            var m = n
            if let c = n.children { m.children = sorted(c, sort) }
            return m
        }
    }

    // MARK: Actions

    func send(_ sig: Int32, to pid: pid_t) -> String? {
        kill(pid, sig) == 0 ? nil : String(cString: strerror(errno))
    }
}

enum Fmt {
    static func bytes(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }
    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }
    static let date: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm:ss"; return f
    }()
    static func age(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}
