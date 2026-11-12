import Foundation

// MARK: - LaunchServices (lsappinfo)

struct LSApp: Identifiable, Hashable, Sendable {
    var id: String { asn }
    var index: Int
    var name: String
    var asn: String
    var bundleID: String?
    var bundlePath: String?
    var executablePath: String?
    var pid: pid_t?
    var type: String?
    var version: String?
    var arch: String?
    var coalition: UInt64?            // jetsam coalition id
    var coalitionPIDs: [pid_t] = []   // `{ … }` after the coalition id
    var relatedCoalitionIDs: [UInt64] = []
    var relatedCoalitionPIDs: [pid_t] = []   // e.g. helpers left over from a previous instance
    var parentASN: String?
    var stateTags: [String] = []      // e.g. "exited-with-subordinates", "!signalled"
    var raw: String

    var exited: Bool { stateTags.contains { $0.hasPrefix("exited") } }
}

enum LSAppInfo {
    static func list() -> [LSApp] {
        parse(Shell.run("/usr/bin/lsappinfo", ["list"], timeout: 10))
    }

    static func parse(_ text: String) -> [LSApp] {
        // `  6) "Google Chrome" ASN:0x0-0x10010: (in front)`: the frontmost app's header carries a trailing tag.
        let header = try! NSRegularExpression(pattern: #"^\s*(\d+)\) "(.*)" (ASN:\S+?):?(?:\s+\(([^)]*)\))?\s*$"#)
        var apps: [LSApp] = []
        var cur: LSApp?
        func flush() { if let c = cur { apps.append(c) }; cur = nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let ns = line as NSString
            if let m = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                cur = LSApp(index: Int(ns.substring(with: m.range(at: 1))) ?? 0,
                            name: ns.substring(with: m.range(at: 2)),
                            asn: ns.substring(with: m.range(at: 3)), raw: line)
                if m.range(at: 4).location != NSNotFound { cur?.stateTags.append(ns.substring(with: m.range(at: 4))) }
                continue
            }
            guard var c = cur else { continue }
            c.raw += "\n" + line
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("bundleID=") { c.bundleID = quoted(t, "bundleID=") }
            else if t.hasPrefix("bundle path=") { c.bundlePath = quoted(t, "bundle path=") }
            else if t.hasPrefix("executable path=") { c.executablePath = quoted(t, "executable path=") }
            else if t.hasPrefix("coalition:") {
                // coalition: 108929  { 15173 15177 }    relatedCoalitionIDs: ( 108927)  relatedCoalitionPIDs: ( 15166)
                let rest = t.dropFirst("coalition:".count).trimmingCharacters(in: .whitespaces)
                c.coalition = rest.split(separator: " ").first.flatMap { UInt64($0) }
                c.coalitionPIDs = numbers(in: rest, between: "{", and: "}")
                c.relatedCoalitionIDs = numbers(in: rest, after: "relatedCoalitionIDs:")
                c.relatedCoalitionPIDs = numbers(in: rest, after: "relatedCoalitionPIDs:")
            }
            else if t.hasPrefix("parentASN=") { c.parentASN = quoted(t, "parentASN=") }
            else if t.hasPrefix("pid = ") {
                let parts = t.split(separator: " ")
                if parts.count > 2 { c.pid = pid_t(parts[2]) }
                c.type = field(t, "type")
                c.version = field(t, "Version")
                if let r = t.range(of: "Arch=") {
                    let rest = t[r.upperBound...]
                    c.arch = rest.split(separator: " ").first.map(String.init)
                }
                for tok in t.split(separator: " ") where tok.hasPrefix("!") { c.stateTags.append(String(tok)) }
                if let o = t.lastIndex(of: "("), let cl = t.lastIndex(of: ")"), o < cl {
                    c.stateTags.append(String(t[t.index(after: o)..<cl]))
                }
            }
            cur = c
        }
        flush()
        return apps
    }

    private static func numbers<T: FixedWidthInteger>(in s: String, between open: Character, and close: Character) -> [T] {
        guard let o = s.firstIndex(of: open), let c = s[o...].firstIndex(of: close) else { return [] }
        return s[s.index(after: o)..<c].split(separator: " ").compactMap { T($0) }
    }

    private static func numbers<T: FixedWidthInteger>(in s: String, after key: String) -> [T] {
        guard let r = s.range(of: key) else { return [] }
        return numbers(in: String(s[r.upperBound...]), between: "(", and: ")")
    }

    private static func quoted(_ s: String, _ prefix: String) -> String? {
        let v = s.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("[ NULL ]") { return nil }
        if v.hasPrefix("\""), let end = v.dropFirst().firstIndex(of: "\"") { return String(v[v.index(after: v.startIndex)..<end]) }
        return v
    }

    private static func field(_ s: String, _ key: String) -> String? {
        guard let r = s.range(of: " \(key)=") else { return nil }
        let rest = s[r.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) }
        }
        return rest.split(separator: " ").first.map(String.init)
    }
}

// MARK: - Background Task Management (sfltool dumpbtm)

struct BTMItem: Identifiable, Hashable, Sendable {
    var id: String { uid + ":" + (fields["UUID"] ?? "\(index)") }
    var uid: String
    var index: Int
    var fields: [String: String]
    var embedded: [String] = []

    var name: String { fields["Name"] ?? "?" }
    var type: String { fields["Type"] ?? "" }
    var disposition: String { fields["Disposition"] ?? "" }
    var identifier: String { fields["Identifier"] ?? "" }
    var developer: String { fields["Developer Name"] ?? "" }
    var teamID: String { fields["Team Identifier"] ?? "" }
    var url: String { fields["URL"] ?? "" }
    var executable: String { fields["Executable Path"] ?? "" }
    var bundleID: String { fields["Bundle Identifier"] ?? "" }
    var parent: String { fields["Parent Identifier"] ?? "" }
    var lastUse: String { fields["Last Use"] ?? "" }
    var enabled: Bool { disposition.contains("[enabled") }
    var allowed: Bool { disposition.contains(" allowed") || disposition.contains("[allowed") }
}

enum BTM {
    /// NOTE: sfltool requests `system.privilege.admin` (password prompt) on every run.
    /// Never call this automatically — only from an explicit user action.
    // Long limit: sfltool waits for the user to type an admin password.
    static func dump() -> [BTMItem] { parse(Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 300)) }

    static func parse(_ text: String) -> [BTMItem] {
        var items: [BTMItem] = []
        var uid = "?"
        var cur: BTMItem?
        var inEmbedded = false
        func flush() { if let c = cur { items.append(c) }; cur = nil }
        for raw in text.split(separator: "\n").map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Records for UID") {
                flush()
                uid = t.replacingOccurrences(of: "Records for UID ", with: "").components(separatedBy: " :").first ?? "?"
                continue
            }
            // Item headers have 1 leading space ("  #1:"), embedded entries are deeper.
            let lead = raw.prefix { $0 == " " }.count
            if t.hasPrefix("#"), t.hasSuffix(":"), lead <= 2 {
                flush()
                inEmbedded = false
                cur = BTMItem(uid: uid, index: Int(t.dropFirst().dropLast()) ?? 0, fields: [:])
                continue
            }
            guard var c = cur else { continue }
            if t == "Embedded Item Identifiers:" { inEmbedded = true; cur = c; continue }
            if inEmbedded, t.hasPrefix("#"), let r = t.range(of: ": ") {
                c.embedded.append(String(t[r.upperBound...])); cur = c; continue
            }
            if let r = t.range(of: ": ") {
                inEmbedded = false
                c.fields[String(t[..<r.lowerBound])] = String(t[r.upperBound...])
            }
            cur = c
        }
        flush()
        return items
    }
}

// MARK: - launchd

struct LaunchdJob: Identifiable, Hashable, Sendable {
    var id: String { label }
    var label: String
    var pid: pid_t?
    var lastExit: String
}

enum Launchd {
    static func list() -> [LaunchdJob] {
        Shell.run("/bin/launchctl", ["list"], mergeStderr: false, timeout: 10)
            .split(separator: "\n").dropFirst().compactMap { line in
                let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard p.count == 3 else { return nil }
                return LaunchdJob(label: p[2], pid: pid_t(p[0]), lastExit: p[1])
            }
    }

    static func printJob(_ label: String) -> String {
        let domain = "gui/\(getuid())/\(label)"
        let out = Shell.run("/bin/launchctl", ["print", domain], timeout: 10)
        if out.contains("Could not find service") {
            return Shell.run("/bin/launchctl", ["print", "system/\(label)"], timeout: 10)
        }
        return out
    }
}
