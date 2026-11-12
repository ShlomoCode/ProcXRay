import Foundation

// Parsers that turn the raw text of lsof / vmmap / sample / log / launchctl into structured data for the
// visual views. Every parser is total: lines it doesn't understand are skipped, and the Raw view keeps
// the original text one click away.

// MARK: - Sizes ("128K", "1.6G", "824")

enum SizeText {
    static func bytes(_ s: Substring) -> UInt64? { bytes(String(s)) }
    static func bytes(_ s: String) -> UInt64? {
        guard let last = s.last else { return nil }
        let mult: Double
        var num = s
        switch last {
        case "K": mult = 0x1p10
        case "M": mult = 0x1p20
        case "G": mult = 0x1p30
        case "T": mult = 0x1p40
        case "P": mult = 0x1p50
        case "B": mult = 1
        default: mult = 1; num += " "
        }
        let digits = num.dropLast()
        // A plain byte count parses exactly; Double would round anything above 2^53.
        if mult == 1, let n = UInt64(digits) { return n }
        // Malformed or truncated output ("nan", "-1", "inf", past 2^64) is skipped, not trapped on.
        guard let v = Double(digits), v.isFinite, v >= 0 else { return nil }
        return UInt64(exactly: (v * mult).rounded())
    }
}

// MARK: - lsof

struct LsofEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case image = "Mapped", file = "Files", dir = "Directories", tcp = "TCP", udp = "UDP",
             unix = "Unix sockets", pipe = "Pipes", device = "Devices", kernel = "Kernel"
        var symbol: String {
            switch self {
            case .image: "memorychip"
            case .file: "doc"
            case .dir: "folder"
            case .tcp: "network"
            case .udp: "antenna.radiowaves.left.and.right"
            case .unix: "point.3.connected.trianglepath.dotted"
            case .pipe: "arrow.left.arrow.right"
            case .device: "cpu"
            case .kernel: "gearshape.2"
            }
        }
    }
    let id: Int
    var fd: String
    var mode: String          // r / w / u (read-write) or ""
    var type: String
    var device: String
    var sizeOff: String
    var node: String
    var name: String
    var kind: Kind

    /// TCP/UDP endpoint split: "a->b (STATE)".
    var endpoints: (local: String, remote: String?, state: String?) {
        var s = name
        var state: String?
        if let o = s.lastIndex(of: "("), s.hasSuffix(")") {
            state = String(s[s.index(after: o)..<s.index(before: s.endIndex)])
            s = s[..<o].trimmingCharacters(in: .whitespaces)
        }
        let parts = s.components(separatedBy: "->")
        return (parts[0], parts.count > 1 ? parts[1] : nil, state)
    }

    var size: UInt64? { sizeOff.hasPrefix("0t") ? nil : UInt64(sizeOff) }
}

enum LsofParser {
    static func parse(_ text: String) -> [LsofEntry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first(where: { $0.hasPrefix("COMMAND") }),
              let nameCol = header.range(of: "NAME")?.lowerBound else { return [] }
        let h = Array(header)
        let nameOffset = header.distance(from: header.startIndex, to: nameCol)
        // Right edges of the right-aligned columns, used to place optional (blank) fields.
        func end(_ title: String) -> Int {
            guard let r = header.range(of: title) else { return -1 }
            return header.distance(from: header.startIndex, to: r.upperBound)
        }
        let cols: [(String, Int)] = [("TYPE", end("TYPE")), ("DEVICE", end("DEVICE")),
                                     ("SIZE", end("SIZE/OFF")), ("NODE", end("NODE"))]
        _ = h
        var out: [LsofEntry] = []
        for line in lines where !line.hasPrefix("COMMAND") {
            let chars = Array(line)
            guard chars.count > 0 else { continue }
            let prefix = String(chars[..<min(nameOffset, chars.count)])
            let name = chars.count > nameOffset ? String(chars[nameOffset...]).trimmingCharacters(in: .whitespaces) : ""
            // Tokens with their end offsets.
            var toks: [(String, Int)] = []
            var i = 0
            let pc = Array(prefix)
            while i < pc.count {
                if pc[i] == " " { i += 1; continue }
                let s = i
                while i < pc.count, pc[i] != " " { i += 1 }
                toks.append((String(pc[s..<i]), i))
            }
            // COMMAND may contain spaces: the pid is the first all-digit token after it.
            guard let pidIdx = toks.firstIndex(where: { Int($0.0) != nil }), toks.count > pidIdx + 2 else { continue }
            let fdRaw = toks[pidIdx + 2].0
            var fields: [String: String] = [:]
            for t in toks[(pidIdx + 3)...] {
                let best = cols.min { abs($0.1 - t.1) < abs($1.1 - t.1) }!
                fields[best.0] = t.0
            }
            var fd = fdRaw, mode = ""
            if let last = fdRaw.last, "rwu".contains(last), fdRaw.dropLast().allSatisfy(\.isNumber), fdRaw.count > 1 {
                fd = String(fdRaw.dropLast()); mode = String(last)
            }
            let type = fields["TYPE"] ?? ""
            let node = fields["NODE"] ?? ""
            let kind: LsofEntry.Kind = {
                switch type {
                case "REG": return fd == "txt" ? .image : .file
                case "DIR": return .dir
                case "IPv4", "IPv6": return node == "UDP" ? .udp : .tcp
                case "unix": return .unix
                case "PIPE", "FIFO": return .pipe
                case "CHR", "BLK": return .device
                default: return .kernel
                }
            }()
            out.append(LsofEntry(id: out.count, fd: fd, mode: mode, type: type, device: fields["DEVICE"] ?? "",
                                 sizeOff: fields["SIZE"] ?? "", node: node, name: name, kind: kind))
        }
        return out
    }
}

// MARK: - vmmap --summary

struct VMRegion: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var virtual: UInt64, resident: UInt64, dirty: UInt64, swapped: UInt64
    var volatile: UInt64, nonvolatile: UInt64, empty: UInt64
    var count: Int
    var note: String
}

struct MallocZone: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var virtual: UInt64, resident: UInt64, dirty: UInt64, swapped: UInt64
    var allocations: Int
    var allocated: UInt64
    var fragSize: UInt64
    var fragPercent: Int
    var regions: Int
}

struct VMSummary: Sendable {
    var header: [(String, String)] = []
    var footprint: UInt64?
    var footprintPeak: UInt64?
    /// "ReadOnly portion of Libraries: Total=3.2G resident=385.6M(12%) …" → title + fields.
    var portions: [(title: String, total: UInt64?, parts: [(String, UInt64?, Int?)])] = []
    var regions: [VMRegion] = []
    var regionTotal: VMRegion?
    var zones: [MallocZone] = []
    var zoneTotal: MallocZone?
    var isEmpty: Bool { regions.isEmpty && zones.isEmpty }
}

enum VmmapParser {
    private static let size = #"(\d+(?:\.\d+)?[KMGTPB]?)"#
    private static let regionRE = try! NSRegularExpression(
        pattern: #"^(.+?)\s+"# + Array(repeating: size + #"\s+"#, count: 7).joined() + #"(\d+)\s*(.*)$"#)
    private static let zoneRE = try! NSRegularExpression(
        pattern: #"^(.+?)\s+"# + Array(repeating: size + #"\s+"#, count: 4).joined()
            + #"(\d+)\s+"# + size + #"\s+"# + size + #"\s+(\d+)%\s+(\d+)\s*$"#)

    static func parse(_ text: String) -> VMSummary {
        var s = VMSummary()
        enum Section { case header, region, zone, other }
        var sec = Section.header
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("REGION TYPE") { sec = .region; continue }
            if t.hasPrefix("MALLOC ZONE") { sec = .zone; continue }
            if t.isEmpty || t.hasPrefix("=====") || t.hasPrefix("VIRTUAL") { continue }
            if t == "----" { sec = .other; continue }
            switch sec {
            case .header:
                if let r = t.range(of: ":") {
                    let k = String(t[..<r.lowerBound]), v = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if k == "Physical footprint" { s.footprint = SizeText.bytes(v) }
                    else if k == "Physical footprint (peak)" { s.footprintPeak = SizeText.bytes(v) }
                    else { s.header.append((k, v)) }
                }
            case .other:
                if let r = t.range(of: ": "), t.contains("=") {
                    var total: UInt64?
                    var parts: [(String, UInt64?, Int?)] = []
                    for tok in t[r.upperBound...].split(separator: " ") {
                        let kv = tok.split(separator: "=", maxSplits: 1)
                        guard kv.count == 2 else { continue }
                        var v = kv[1]
                        var pct: Int?
                        if let o = v.firstIndex(of: "(") {
                            pct = Int(v[v.index(after: o)...].prefix { $0.isNumber })
                            v = v[..<o]
                        }
                        if kv[0] == "Total" { total = SizeText.bytes(v) } else { parts.append((String(kv[0]), SizeText.bytes(v), pct)) }
                    }
                    s.portions.append((String(t[..<r.lowerBound]), total, parts))
                }
            case .region:
                guard let g = groups(regionRE, line), g.count == 10 else { continue }
                let b = g[1...7].map { SizeText.bytes($0) ?? 0 }
                let r = VMRegion(name: g[0], virtual: b[0], resident: b[1], dirty: b[2], swapped: b[3],
                                 volatile: b[4], nonvolatile: b[5], empty: b[6], count: Int(g[8]) ?? 0,
                                 note: g[9])
                if r.name == "TOTAL" { s.regionTotal = r } else if !r.name.hasPrefix("TOTAL") { s.regions.append(r) }
            case .zone:
                guard let g = groups(zoneRE, line), g.count == 10 else { continue }
                let z = MallocZone(name: g[0], virtual: SizeText.bytes(g[1]) ?? 0, resident: SizeText.bytes(g[2]) ?? 0,
                                   dirty: SizeText.bytes(g[3]) ?? 0, swapped: SizeText.bytes(g[4]) ?? 0,
                                   allocations: Int(g[5]) ?? 0, allocated: SizeText.bytes(g[6]) ?? 0,
                                   fragSize: SizeText.bytes(g[7]) ?? 0, fragPercent: Int(g[8]) ?? 0, regions: Int(g[9]) ?? 0)
                if z.name == "TOTAL" { s.zoneTotal = z } else { s.zones.append(z) }
            }
        }
        return s
    }
}

/// Capture groups 1…n of the first match, trimmed.
func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (1..<m.numberOfRanges).map {
        let r = m.range(at: $0)
        return r.location == NSNotFound ? "" : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - sample

final class CallNode: Identifiable, @unchecked Sendable {
    let id: Int
    let count: Int
    let symbol: String
    let library: String?
    let isThread: Bool
    var children: [CallNode] = []
    weak var parent: CallNode?
    init(id: Int, count: Int, symbol: String, library: String?, isThread: Bool) {
        self.id = id; self.count = count; self.symbol = symbol; self.library = library; self.isThread = isThread
    }
}

struct SampleReport: Sendable {
    var header: [(String, String)] = []
    var threads: [CallNode] = []
    var topOfStack: [(symbol: String, library: String?, count: Int)] = []
    var totalSamples: Int { threads.map(\.count).max() ?? 0 }
}

enum SampleParser {
    static func parse(_ text: String) -> SampleReport {
        var rep = SampleReport()
        enum Section { case header, graph, top, other }
        var sec = Section.header
        var stack: [(depth: Int, node: CallNode)] = []
        var nextID = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "Call graph:" { sec = .graph; continue }
            if t.hasPrefix("Total number in stack") { sec = .other; continue }
            if t.hasPrefix("Sort by top of stack") { sec = .top; continue }
            if t.hasPrefix("Binary Images:") { sec = .other; continue }
            switch sec {
            case .header:
                if t == "----" { continue }
                if let r = t.range(of: ":"), !t.hasPrefix("Sampl"), !t.hasPrefix("Analysis") {
                    let v = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { rep.header.append((String(t[..<r.lowerBound]), v)) }
                }
            case .graph:
                guard !t.isEmpty else { continue }
                // Leading spaces and tree glyphs (+ ! : |), then "<count> <frame>".
                let chars = Array(line)
                var i = 0
                while i < chars.count, " +!:|".contains(chars[i]) { i += 1 }
                let depth = (i - 4) / 2
                let rest = String(chars[i...])
                guard let sp = rest.firstIndex(of: " "), let count = Int(rest[..<sp]) else { continue }
                let frame = rest[rest.index(after: sp)...].trimmingCharacters(in: .whitespaces)
                let isThread = depth == 0
                let (sym, lib) = isThread ? (frame, nil) : splitFrame(frame)
                let node = CallNode(id: nextID, count: count, symbol: sym, library: lib, isThread: isThread)
                nextID += 1
                while let last = stack.last, last.depth >= depth { stack.removeLast() }
                if let p = stack.last { node.parent = p.node; p.node.children.append(node) } else { rep.threads.append(node) }
                stack.append((depth, node))
            case .top:
                // "mach_msg2_trap  (in libsystem_kernel.dylib)        4260"
                guard let sp = t.lastIndex(of: " "), let n = Int(t[t.index(after: sp)...]) else { continue }
                let (sym, lib) = splitFrame(t[..<sp].trimmingCharacters(in: .whitespaces))
                rep.topOfStack.append((sym, lib, n))
            case .other: continue
            }
        }
        return rep
    }

    /// "-[NSApplication run]  (in AppKit) + 396  [0x1967a2920]" → ("-[NSApplication run]", "AppKit")
    static func splitFrame(_ f: String) -> (String, String?) {
        guard let r = f.range(of: "  (in ") else { return (f, nil) }
        let sym = String(f[..<r.lowerBound])
        let after = f[r.upperBound...]
        let lib = after.firstIndex(of: ")").map { String(after[..<$0]) }
        return (sym, lib)
    }
}

// MARK: - log show --style compact

struct LogEntry: Identifiable, Sendable {
    enum Level: String, CaseIterable, Sendable {
        case fault = "Fault", error = "Error", `default` = "Default", info = "Info", debug = "Debug", activity = "Activity"
        init(code: String) {
            switch code {
            case "F", "Ft": self = .fault
            case "E", "Er": self = .error
            case "I", "In": self = .info
            case "Db", "D": self = .debug
            case "A", "Ac", "At": self = .activity
            default: self = .default
            }
        }
    }
    let id: Int
    var date: Date?
    var time: String
    var level: Level
    var process: String
    var pid: String
    var thread: String
    var subsystem: String
    var message: String
}

enum LogParser {
    private static let re = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\S+)\s+(.+?)\[(\d+):([0-9a-fA-F]+)\]\s+(?:\[([^\]]*)\]\s+)?(.*)$"#)
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func parse(_ text: String) -> [LogEntry] {
        var out: [LogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let g = groups(re, line), g.count == 7 {
                out.append(LogEntry(id: out.count, date: df.date(from: g[0]), time: String(g[0].dropFirst(11)),
                                    level: .init(code: g[1]), process: g[2], pid: g[3], thread: g[4],
                                    subsystem: g[5], message: g[6]))
            } else if !out.isEmpty, !line.hasPrefix("Timestamp"), !line.isEmpty {
                out[out.count - 1].message += "\n" + line   // multi-line message continuation
            }
        }
        return out
    }
}

// MARK: - launchctl print / procinfo (indentation tree)

final class KVNode: Identifiable, @unchecked Sendable {
    let id: Int
    let key: String
    let value: String?
    var children: [KVNode] = []
    init(id: Int, key: String, value: String?) { self.id = id; self.key = key; self.value = value }
    var isLeaf: Bool { children.isEmpty }
}

enum LaunchctlParser {
    /// Indentation-based: works for both `key = {` blocks and procinfo's bare indented sections.
    static func parse(_ text: String) -> [KVNode] {
        var roots: [KVNode] = []
        var stack: [(indent: Int, node: KVNode)] = []
        var nextID = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Also covers procinfo's OpenStep-style plists: `"k" = true;`, `"k" = ( "a", "b" );`.
            if t.isEmpty || ["}", "{", ")", "(", "};", ");", "},", "),"].contains(t) { continue }
            var indent = 0
            for c in line { if c == "\t" { indent += 4 } else if c == " " { indent += 1 } else { break } }
            var key = t, value: String?
            for sep in [" => ", " = ", ": "] {
                if let r = t.range(of: sep) {
                    key = String(t[..<r.lowerBound]); value = String(t[r.upperBound...]); break
                }
            }
            func clean(_ s: String) -> String {
                var s = s
                while let l = s.last, l == ";" || l == "," { s.removeLast() }
                if s.hasPrefix("\""), s.hasSuffix("\""), s.count > 1 { s = String(s.dropFirst().dropLast()) }
                return s
            }
            key = clean(key)
            value = value.map(clean)
            if value == "{" || value == "(" { value = nil }
            if key.hasSuffix(" = {") { key = String(key.dropLast(4)) }
            if key.hasSuffix("{") { key = key.dropLast().trimmingCharacters(in: .whitespaces) }
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count > 1 { key = String(key.dropFirst().dropLast()) }
            let node = KVNode(id: nextID, key: key, value: value)
            nextID += 1
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if let p = stack.last { p.node.children.append(node) } else { roots.append(node) }
            stack.append((indent, node))
        }
        // `gui/501/com.apple.Finder = { … }` → unwrap the single top-level service block.
        if roots.count == 1, let r = roots.first, !r.children.isEmpty, r.value == nil {
            return [KVNode(id: -1, key: "Service", value: r.key)] + r.children
        }
        return roots
    }
}

// MARK: - lsappinfo record → key/value rows

enum LSRecordParser {
    private static let tokenRE = try! NSRegularExpression(pattern: #"(?<![\w])([A-Za-z]\w*)=("[^"]*"|\[[^\]]*\]|\S+)"#)

    static func rows(_ raw: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for (i, line) in raw.split(separator: "\n").map(String.init).enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if i == 0 { continue }
            if t.hasPrefix("pid = ") || t.hasPrefix("pid=") {
                // pid = 720 token=[…] type="UIElement" flavor=3 Version="…" Arch=ARM64
                let parts = t.split(separator: " ", maxSplits: 3)
                if parts.count > 2 { out.append(("pid", String(parts[2]))) }
                let ns = t as NSString
                for m in tokenRE.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                    let k = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    if k == "pid" { continue }
                    out.append((k, unquote(ns.substring(with: m.range(at: 2)))))
                }
                for tok in t.split(separator: " ") where tok.hasPrefix("!") { out.append(("flag", String(tok))) }
                continue
            }
            let eq = t.range(of: "="), colon = t.range(of: ":")
            let sep = [eq, colon].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
            if let sep {
                let k = t[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
                let v = t[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\""), v.contains("\" \"") {
                    out.append((k, v.split(separator: " ").map { unquote(String($0)) }.joined(separator: "\n")))
                } else {
                    out.append((k, unquote(v)))
                }
            } else {
                out.append(("", t))
            }
        }
        return out
    }

    static func unquote(_ s: String) -> String {
        if s == "[ NULL ]" { return "—" }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count > 1 { return String(s.dropFirst().dropLast()) }
        return s
    }
}
