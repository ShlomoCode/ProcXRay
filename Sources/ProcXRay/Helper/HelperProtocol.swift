import Foundation
import Security

/// Shared between the app and the root helper (same binary, run with `--helper`).
enum HelperConfig {
    static let machService = "local.procxray.helper"
    static let plistName = "local.procxray.helper.plist"
    static let bundleID = "local.procxray"

    /// Team ID and cdhash of this binary's signature (app and helper are the same binary).
    /// Note: an "Apple Development: Name (XXXXXXXXXX)" certificate's parenthesised ID is NOT the team ID.
    private static let signature: (team: String, cdhash: String)? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any],
              let team = d[kSecCodeInfoTeamIdentifier as String] as? String,
              let unique = d[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return (team, unique.map { String(format: "%02x", $0) }.joined())
    }()
    static var teamID: String? { signature?.team }

    /// Both sides require the peer to be this exact binary: same identifier and team, and the same cdhash.
    /// The cdhash pin is what matters — identifier and team alone would admit anything else signed with
    /// the same certificate. Unsigned/ad-hoc builds get an unsatisfiable requirement, so the helper can
    /// never be driven by unsigned code.
    static var peerRequirement: String {
        guard let s = signature else { return #"identifier "never.matches" and anchor apple"# }
        return #"identifier "\#(bundleID)" and anchor apple generic and certificate leaf[subject.OU] = "\#(s.team)" and cdhash H"\#(s.cdhash)""#
    }
    /// Bumped whenever the XPC interface changes.
    static let protocolVersion = 1
}

/// Read-only surface. No call accepts a path, a command or free-form arguments.
@objc protocol HelperProtocol {
    func version(reply: @escaping (Int, Int32) -> Void)                 // (protocolVersion, helper pid)
    func allMetrics(reply: @escaping (Data) -> Void)                    // JSON [PrivMetrics]
    func argsEnv(pid: Int32, reply: @escaping (Data?) -> Void)          // JSON PrivArgsEnv
    func runTool(_ tool: Int, pid: Int32, reply: @escaping (String) -> Void)
}

/// Allowlisted tools; the helper builds the argv itself.
enum HelperTool: Int, CaseIterable {
    case lsof = 1, vmmap, sample, launchctlProcinfo, btmDump

    func argv(pid: Int32) -> (String, [String])? {
        switch self {
        case .lsof: return pid > 0 ? ("/usr/sbin/lsof", ["-n", "-P", "-p", "\(pid)"]) : nil
        case .vmmap: return pid > 0 ? ("/usr/bin/vmmap", ["--summary", "\(pid)"]) : nil
        // Without -file, sample also writes its report to /tmp (as root, world-readable when run by the helper).
        case .sample: return pid > 0 ? ("/usr/bin/sample", ["\(pid)", "1", "-mayDie", "-file", "/dev/stdout"]) : nil
        case .launchctlProcinfo: return pid > 0 ? ("/bin/launchctl", ["procinfo", "\(pid)"]) : nil
        case .btmDump: return ("/usr/bin/sfltool", ["dumpbtm"])
        }
    }

    /// Seconds before the helper kills the tool. Under HelperClient.run's 60 s wait, so the reply still arrives.
    var timeout: Double {
        switch self {
        case .sample: 45   // 1 s of sampling, then symbolication: ~13 s for a 39-thread daemon
        case .vmmap, .btmDump: 30
        case .lsof: 20
        case .launchctlProcinfo: 10
        }
    }
    /// Output beyond this is dropped: it goes back as one XPC reply and the app parses all of it.
    static let maxOutput = 8 << 20
}

struct PrivMetrics: Codable, Sendable {
    var pid: Int32
    var rss: UInt64?
    var virt: UInt64?
    var threads: Int32?
    var cpuNanos: UInt64?
    var footprint: UInt64?
    var diskRead: UInt64?
    var diskWrite: UInt64?
    var energyNJ: UInt64?
    var wakeups: UInt64?
    var responsible: Int32?
    var sandboxed: Bool?
}

struct PrivArgsEnv: Codable, Sendable {
    var execPath: String
    var args: [String]
    var env: [String]
    var cwd: String?
}
