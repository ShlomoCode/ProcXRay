import Foundation

/// Runs as root under launchd when the binary is started with `--helper`.
enum HelperDaemon {
    static func run() -> Never {
        // Anything a tool writes as root stays private to root.
        umask(0o077)
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: HelperConfig.machService)
        // Reject any client that isn't ProcXRay signed by our team (enforced by the kernel/XPC, not by us parsing anything).
        listener.setConnectionCodeSigningRequirement(HelperConfig.peerRequirement)
        listener.delegate = delegate
        listener.resume()
        NSLog("ProcXRay helper %d listening on %@", getpid(), HelperConfig.machService)
        withExtendedLifetime((listener, delegate)) { dispatchMain() }
    }

    final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        private var live = 0
        private let q = DispatchQueue(label: "helper.connections")

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            c.exportedObject = Service(callerUID: c.effectiveUserIdentifier)
            q.sync { live += 1 }
            c.invalidationHandler = { [weak self] in self?.connectionEnded() }
            c.resume()
            return true
        }

        /// Exit ~10s after the last client goes away; launchd relaunches on demand.
        private func connectionEnded() {
            q.async {
                self.live -= 1
                guard self.live <= 0 else { return }
                self.q.asyncAfter(deadline: .now() + 10) {
                    if self.live <= 0 { NSLog("ProcXRay helper idle, exiting"); exit(0) }
                }
            }
        }
    }

    /// One per connection. The helper hands a caller nothing it couldn't get on its own or with sudo:
    /// another user's process (arguments, environment, tools) only for an admin caller.
    final class Service: NSObject, HelperProtocol {
        private let callerUID: uid_t
        private let callerIsAdmin: Bool

        init(callerUID: uid_t) {
            self.callerUID = callerUID
            callerIsAdmin = Native.isAdmin(callerUID)
        }

        private func mayInspect(_ pid: Int32) -> Bool {
            if callerIsAdmin { return true }
            guard let p = Native.process(pid) else { return false }
            return p.uid == callerUID && p.ruid == callerUID
        }

        func version(reply: @escaping (Int, Int32) -> Void) { reply(HelperConfig.protocolVersion, getpid()) }

        func allMetrics(reply: @escaping (Data) -> Void) {
            var out: [PrivMetrics] = []
            for k in Native.allProcesses() where k.pid > 0 {
                var m = PrivMetrics(pid: k.pid)
                if let ti = Native.taskInfo(k.pid) {
                    m.rss = ti.pti_resident_size
                    m.virt = ti.pti_virtual_size
                    m.threads = ti.pti_threadnum
                    m.cpuNanos = Native.machToNanos(ti.pti_total_user &+ ti.pti_total_system)
                }
                if let ru = Native.rusage(k.pid) {
                    m.footprint = ru.ri_phys_footprint
                    m.diskRead = ru.ri_diskio_bytesread
                    m.diskWrite = ru.ri_diskio_byteswritten
                    m.energyNJ = ru.ri_billed_energy
                    m.wakeups = ru.ri_pkg_idle_wkups &+ ru.ri_interrupt_wkups
                    if m.cpuNanos == nil { m.cpuNanos = Native.machToNanos(ru.ri_user_time &+ ru.ri_system_time) }
                }
                m.responsible = Native.responsible(k.pid)
                m.sandboxed = Native.sandboxed(k.pid)
                out.append(m)
            }
            reply((try? JSONEncoder().encode(out)) ?? Data())
        }

        func argsEnv(pid: Int32, reply: @escaping (Data?) -> Void) {
            guard pid > 0, mayInspect(pid), let a = Native.argsEnv(pid) else { reply(nil); return }
            let v = PrivArgsEnv(execPath: a.execPath, args: a.args, env: a.env, cwd: Native.cwd(pid))
            reply(try? JSONEncoder().encode(v))
        }

        func runTool(_ tool: Int, pid: Int32, reply: @escaping (String) -> Void) {
            guard let t = HelperTool(rawValue: tool), let (path, args) = t.argv(pid: pid) else {
                reply("helper: rejected tool \(tool) pid \(pid)")
                return
            }
            guard t == .btmDump ? callerIsAdmin : mayInspect(pid) else {
                reply("helper: only an admin user can inspect another user's processes or all background items")
                return
            }
            reply(Shell.run(path, args))
        }
    }
}
