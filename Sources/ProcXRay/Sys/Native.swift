import Darwin
import Foundation

/// Thin wrappers over libproc / sysctl / private libsystem symbols.
/// Everything here works unprivileged; calls against processes we can't inspect return nil.
enum Native {
    // MARK: Private symbols resolved at runtime

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private typealias SandboxCheckFn = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

    private static let handle = dlopen(nil, RTLD_NOW)

    private static let respFn: RespFn? = {
        guard let s = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(s, to: RespFn.self)
    }()

    private static let sandboxCheckFn: SandboxCheckFn? = {
        guard let s = dlsym(handle, "sandbox_check") else { return nil }
        return unsafeBitCast(s, to: SandboxCheckFn.self)
    }()

    static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    static func machToNanos(_ t: UInt64) -> UInt64 { t &* timebase.numer / timebase.denom }

    // MARK: Process enumeration

    struct KProc {
        var pid: pid_t
        var ppid: pid_t
        var pgid: pid_t
        var uid: uid_t
        var ruid: uid_t
        var comm: String
        var start: Date
        var stat: Int8
        var flags: Int32
        var tty: Int32
    }

    static func allProcesses() -> [KProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 4
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        let n = size / stride
        var out: [KProc] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            var k = buf[i]
            let comm = withUnsafePointer(to: &k.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let st = k.kp_proc.p_un.__p_starttime
            out.append(KProc(
                pid: k.kp_proc.p_pid,
                ppid: k.kp_eproc.e_ppid,
                pgid: k.kp_eproc.e_pgid,
                uid: k.kp_eproc.e_ucred.cr_uid,
                ruid: k.kp_eproc.e_pcred.p_ruid,
                comm: comm,
                start: Date(timeIntervalSince1970: Double(st.tv_sec) + Double(st.tv_usec) / 1e6),
                stat: Int8(bitPattern: UInt8(k.kp_proc.p_stat)),
                flags: k.kp_proc.p_flag,
                tty: k.kp_eproc.e_tdev
            ))
        }
        return out
    }

    // MARK: Per-pid info

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var ti = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sz) == sz ? ti : nil
    }

    static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? ri : nil
    }

    /// Returns (resource coalition id, jetsam coalition id).
    static func coalition(_ pid: pid_t) -> (UInt64, UInt64)? {
        var buf = [UInt64](repeating: 0, count: 5)
        let n = proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */, 0, &buf, Int32(buf.count * 8))
        return n >= 16 ? (buf[0], buf[1]) : nil
    }

    static func responsible(_ pid: pid_t) -> pid_t? {
        guard let f = respFn else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    /// 1 = sandboxed, 0 = not, nil = unknown.
    static func sandboxed(_ pid: pid_t) -> Bool? {
        guard let f = sandboxCheckFn else { return nil }
        let r = f(pid, nil, 0)
        return r < 0 ? nil : r != 0
    }

    static func cwd(_ pid: pid_t) -> String? {
        var vi = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, sz) == sz else { return nil }
        return withUnsafeBytes(of: &vi.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    struct ArgsEnv { var execPath: String; var args: [String]; var env: [String] }

    static func argsEnv(_ pid: pid_t) -> ArgsEnv? {
        var argmax: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &sz, nil, 0) == 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var size = buf.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        func readCString() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        let exec = readCString() ?? ""
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        for _ in 0..<max(0, Int(argc)) { if let a = readCString() { args.append(a) } }
        var env: [String] = []
        while i < size, buf[i] != 0, let e = readCString() { env.append(e) }
        return ArgsEnv(execPath: exec, args: args, env: env)
    }

    static func userName(_ uid: uid_t) -> String {
        if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
        return String(uid)
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

/// Runs a command-line tool and returns stdout (stderr merged when requested).
enum Shell {
    static func run(_ path: String, _ args: [String], mergeStderr: Bool = true) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        do { try p.run() } catch { return "failed to run \(path): \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
