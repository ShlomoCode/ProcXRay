import Darwin
import Foundation

/// `ProcXRay --bench`: times each stage of a refresh tick, in wall-clock and this process's CPU time.
/// Child-process CPU (lsappinfo, launchctl) is reported separately via RUSAGE_CHILDREN.
enum Bench {
    @MainActor static func run() {
        let n = 20
        func cpu(_ who: Int32) -> Double {
            var r = rusage(); getrusage(who, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        func time(_ label: String, _ body: () -> Void) {
            let w0 = Date(), c0 = cpu(RUSAGE_SELF), k0 = cpu(RUSAGE_CHILDREN)
            for _ in 0..<n { body() }
            let w = Date().timeIntervalSince(w0) / Double(n) * 1000
            let c = (cpu(RUSAGE_SELF) - c0) / Double(n) * 1000
            let k = (cpu(RUSAGE_CHILDREN) - k0) / Double(n) * 1000
            print(String(format: "%-28@ wall %7.2f ms   cpu %7.2f ms   children cpu %6.2f ms", label as NSString, w, c, k))
        }
        let helper = HelperClient.shared.probe().isRunning
        print("helper running: \(helper); \(n) iterations each")
        time("lsappinfo list (spawn)") { _ = Shell.run("/usr/bin/lsappinfo", ["list"]) }
        let lsText = Shell.run("/usr/bin/lsappinfo", ["list"])
        time("lsappinfo parse") { _ = LSAppInfo.parse(lsText) }
        time("launchctl list") { _ = Launchd.list() }
        time("sysctl allProcesses") { _ = Native.allProcesses() }
        let pids = Native.allProcesses().map(\.pid).filter { $0 >= 0 }
        time("per-pid path") { for p in pids { _ = Native.path(p) } }
        time("per-pid responsible") { for p in pids { _ = Native.responsible(p) } }
        time("per-pid coalition") { for p in pids { _ = Native.coalition(p) } }
        time("per-pid taskInfo") { for p in pids { _ = Native.taskInfo(p) } }
        time("per-pid rusage") { for p in pids { _ = Native.rusage(p) } }
        time("per-pid sandboxed") { for p in pids { _ = Native.sandboxed(p) } }
        time("per-pid userName") { for p in Native.allProcesses() { _ = Native.userName(p.uid) } }
        if helper { time("helper allMetrics (XPC)") { _ = HelperClient.shared.allMetrics() } }
        let priv = helper ? HelperClient.shared.allMetrics() : nil
        time("full snapshot()") { _ = Store.snapshot(prevCPU: [:], signCache: [:], priv: priv) }
        let snap = Store.snapshot(prevCPU: [:], signCache: [:], priv: priv)
        let store = Store(); store.procs = snap.procs; store.lsApps = snap.ls
        for g in Grouping.allCases {
            time("nodes(\(g.label))") {
                store.procs = snap.procs   // bump the cache generation so it really rebuilds
                _ = store.nodes(grouping: g, filter: "", sort: [KeyPathComparator(\ProcNode.pidKey)])
            }
        }
        time("ghosts()") { _ = Store.ghosts(procs: snap.procs, lsApps: snap.ls) }
        let one = Array(snap.procs.values.prefix(50))
        time("CodeSign.inspect x50") { for p in one { _ = CodeSign.inspect(pid: p.pid, path: p.path) } }
    }
}
