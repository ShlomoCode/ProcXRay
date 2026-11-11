import SwiftUI

// Visual renderings of the parsed tool outputs (see Sys/Parsers.swift). Every pane keeps a
// Visual / Raw switch; the choice is shared app-wide through @AppStorage.

// MARK: - Shared bits

struct RawToggle: View {
    @Binding var showRaw: Bool
    var body: some View {
        Picker("", selection: $showRaw) {
            Label("Visual", systemImage: "chart.bar.doc.horizontal").tag(false)
            Label("Raw", systemImage: "text.alignleft").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between the parsed view and the tool's raw text output")
    }
}

/// Header bar + Visual/Raw switch for panes whose text is already in hand.
struct OutputPane<Visual: View>: View {
    let raw: String
    var filterable = false
    let visual: (String) -> Visual
    @AppStorage("showRawOutput") private var showRaw = false
    @State private var filter = ""

    init(raw: String, filterable: Bool = false, @ViewBuilder visual: @escaping (String) -> Visual) {
        self.raw = raw; self.filterable = filterable; self.visual = visual
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RawToggle(showRaw: $showRaw)
                Spacer()
                if filterable || showRaw {
                    TextField("filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                }
            }
            .padding(6)
            Divider()
            if showRaw {
                MonoText(text: filterLines(raw, filter))
            } else {
                visual(filter)
            }
        }
    }
}

func filterLines(_ s: String, _ f: String) -> String {
    f.isEmpty ? s : s.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(f) }.joined(separator: "\n")
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Inline horizontal bar, `fraction` of a fixed track.
struct MiniBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var width: CGFloat = 70
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.12))
            Capsule().fill(color.gradient)
                .frame(width: max(fraction > 0 ? 2 : 0, width * min(max(fraction, 0), 1)))
        }
        .frame(width: width, height: 6)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var sub: String? = nil
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(color)
                .monospacedDigit()
            if let sub { Text(verbatim: sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 96, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Selectable key/value grid (no scroll view of its own).
struct KVGrid: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    ValueView(key: r.0, value: r.1)
                }
            }
        }
    }
}

/// Renders a launchd / LaunchServices value with a little semantics: states as coloured badges,
/// `a | b | c` flag lists as pills, everything else as selectable monospaced text.
struct ValueView: View {
    let key: String
    let value: String
    var body: some View {
        let k = key.lowercased()
        if k == "state" || k == "job state" {
            Pill(text: value, color: value == "running" || value == "active" ? .green : (value.contains("not") ? .secondary : .orange))
        } else if k == "flag" {
            Pill(text: value, color: .orange)
        } else if value.contains(" | ") {
            FlowPills(items: value.components(separatedBy: " | "))
        } else if k.contains("exit"), value != "0", value != "(never exited)", value != "-" {
            Text(verbatim: value).foregroundStyle(.red).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        } else {
            Text(verbatim: value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

struct FlowPills: View {
    let items: [String]
    var color: Color = .accentColor
    var body: some View {
        HStack(spacing: 4) { ForEach(items, id: \.self) { Pill(text: $0, color: color) } }
    }
}

struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var trailing: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
                if let trailing { Text(verbatim: trailing).foregroundStyle(.secondary) }
                Spacer()
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Shown in place of a visual view when the parser found nothing (error text, permission notes…).
struct UnparsedNote: View {
    let raw: String
    var body: some View {
        VStack(spacing: 0) {
            Label("Nothing to visualise — showing the tool's output.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            MonoText(text: raw)
        }
    }
}

private func stableHue(_ s: String) -> Double {
    var h: UInt32 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt32(b) }
    return Double(h % 360) / 360
}

func libColor(_ lib: String?) -> Color {
    guard let lib else { return .secondary }
    return Color(hue: stableHue(lib), saturation: 0.55, brightness: 0.8)
}

// MARK: - lsof

extension LsofEntry.Kind: Identifiable {
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .image: .purple
        case .file: .blue
        case .dir: .cyan
        case .tcp: .green
        case .udp: .teal
        case .unix: .indigo
        case .pipe: .orange
        case .device: .gray
        case .kernel: .brown
        }
    }
}

extension LsofEntry {
    var fdSort: Int { Int(fd) ?? (fd == "cwd" ? -3 : fd == "txt" ? -2 : -1) }
    var kindName: String { kind.rawValue }
    var sizeSort: UInt64 { size ?? 0 }
}

struct LsofView: View {
    let entries: [LsofEntry]
    let filter: String
    @State private var kinds: Set<LsofEntry.Kind> = []
    @State private var sort = [KeyPathComparator(\LsofEntry.fdSort)]

    var body: some View {
        let counts = Dictionary(grouping: entries, by: \.kind).mapValues(\.count)
        let rows = entries.filter {
            (kinds.isEmpty || kinds.contains($0.kind)) &&
            (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.fd.contains(filter) || $0.type.localizedCaseInsensitiveContains(filter))
        }.sorted(using: sort)
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LsofEntry.Kind.allCases.filter { counts[$0] != nil }) { k in
                        let on = kinds.contains(k)
                        Button {
                            if on { kinds.remove(k) } else { kinds.insert(k) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: k.symbol)
                                Text(k.rawValue)
                                Text(verbatim: "\(counts[k] ?? 0)").bold().monospacedDigit()
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).frame(height: 22)
                            .foregroundStyle(on ? .white : k.color)
                            .background(on ? AnyShapeStyle(k.color) : AnyShapeStyle(k.color.opacity(0.14)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if !kinds.isEmpty { Button("Show all") { kinds = [] }.controlSize(.small) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 34)
            // Proportion strip: one segment per kind.
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(LsofEntry.Kind.allCases.filter { counts[$0] != nil }) { k in
                        Rectangle().fill(k.color.opacity(kinds.isEmpty || kinds.contains(k) ? 0.85 : 0.2))
                            .frame(width: max(2, g.size.width * Double(counts[k] ?? 0) / Double(max(entries.count, 1)) - 1))
                    }
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 8).padding(.bottom, 6)
            Table(rows, sortOrder: $sort) {
                TableColumn("FD", value: \.fdSort) { e in
                    HStack(spacing: 4) {
                        Text(e.fd).monospacedDigit()
                        if !e.mode.isEmpty {
                            Pill(text: e.mode == "u" ? "rw" : e.mode, color: e.mode == "r" ? .blue : .orange)
                        }
                    }
                }.width(min: 66, ideal: 74, max: 100)
                TableColumn("Kind", value: \.kindName) { e in
                    Label(e.kind == .image ? "mapped" : e.type, systemImage: e.kind.symbol).foregroundStyle(e.kind.color)
                }.width(min: 96, ideal: 104, max: 140)
                TableColumn("Name", value: \.name) { e in NameCell(e: e) }
                TableColumn("Size", value: \.sizeSort) { e in
                    Text(e.size.map { Fmt.bytes($0) } ?? "").monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 80, max: 100)
            }
        }
    }

    struct NameCell: View {
        let e: LsofEntry
        var body: some View {
            switch e.kind {
            case .tcp, .udp:
                let p = e.endpoints
                HStack(spacing: 6) {
                    Text(p.local).font(.system(.body, design: .monospaced))
                    if let r = p.remote {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(r).font(.system(.body, design: .monospaced))
                    }
                    if let s = p.state {
                        Pill(text: s, color: s == "ESTABLISHED" ? .green : s == "LISTEN" ? .blue : .orange)
                    }
                }
                .textSelection(.enabled)
            case .file, .image, .dir:
                let slash = e.name.lastIndex(of: "/")
                let dir = slash.map { String(e.name[...$0]) } ?? ""
                let leaf = slash.map { String(e.name[e.name.index(after: $0)...]) } ?? e.name
                HStack(spacing: 0) {
                    Text(dir).foregroundStyle(.secondary)
                    Text(leaf)
                }
                .lineLimit(1).truncationMode(.head)
                .help(e.name)
            default:
                Text(e.name.isEmpty ? "—" : e.name).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - vmmap

struct VmmapView: View {
    let s: VMSummary
    let filter: String
    enum Mode: String, CaseIterable { case chart = "Chart", regions = "Regions", zones = "Malloc Zones" }
    @State private var mode = Mode.chart
    @State private var regionSort = [KeyPathComparator(\VMRegion.resident, order: .reverse)]
    @State private var zoneSort = [KeyPathComparator(\MallocZone.allocated, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StatTile(title: "Physical footprint", value: Fmt.bytes(s.footprint),
                             sub: s.footprintPeak.map { "peak \(Fmt.bytes($0))" }, color: .accentColor)
                    if let t = s.regionTotal {
                        StatTile(title: "Resident", value: Fmt.bytes(t.resident))
                        StatTile(title: "Dirty", value: Fmt.bytes(t.dirty), color: .orange)
                        StatTile(title: "Swapped", value: Fmt.bytes(t.swapped), color: .purple)
                        StatTile(title: "Regions", value: "\(t.count)")
                    }
                    if let z = s.zoneTotal {
                        StatTile(title: "Malloc allocated", value: Fmt.bytes(z.allocated),
                                 sub: "\(z.allocations.formatted()) allocations · \(z.fragPercent)% frag",
                                 color: z.fragPercent > 50 ? .red : .primary)
                    }
                }
                .padding(.horizontal, 10)
            }
            if let fp = s.footprint, let peak = s.footprintPeak, peak > 0 {
                HStack(spacing: 8) {
                    Text("Footprint vs peak").font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    MiniBar(fraction: Double(fp) / Double(peak), width: 220)
                    Text(verbatim: String(format: "%.0f%%", 100 * Double(fp) / Double(peak))).font(.caption).monospacedDigit()
                }
                .padding(.horizontal, 10)
            }
            ForEach(Array(s.portions.enumerated()), id: \.offset) { _, p in
                PortionBar(title: p.title, total: p.total, parts: p.parts).padding(.horizontal, 10)
            }
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.horizontal, 10)
            switch mode {
            case .chart: chart
            case .regions: regionTable
            case .zones: zoneTable
            }
        }
        .padding(.top, 8)
    }

    private var filteredRegions: [VMRegion] {
        s.regions.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var chart: some View {
        let top = Array(filteredRegions.sorted { $0.resident + $0.swapped > $1.resident + $1.swapped }.prefix(20))
        let mx = Double(top.map { $0.resident + $0.swapped }.max() ?? 1)
        let segs: [(String, Color)] = [("Resident (clean)", Color.blue.opacity(0.55)), ("Resident (dirty)", .orange),
                                        ("Swapped / compressed", Color.purple.opacity(0.7))]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Largest regions by memory in use").font(.caption).foregroundStyle(.secondary)
                ForEach(segs, id: \.0) { s in
                    HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(s.1).frame(width: 10, height: 10); Text(s.0) }
                        .font(.caption)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(top) { r in
                        let dirty = min(r.dirty, r.resident)
                        let parts = [Double(r.resident - dirty), Double(dirty), Double(r.swapped)]
                        HStack(spacing: 8) {
                            Text(r.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                .frame(width: 190, alignment: .trailing)
                            GeometryReader { g in
                                HStack(spacing: 0) {
                                    ForEach(0..<3, id: \.self) { i in
                                        Rectangle().fill(segs[i].1).frame(width: g.size.width * parts[i] / max(mx, 1))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .frame(height: 14)
                            Text(Fmt.bytes(r.resident + r.swapped)).font(.system(size: 11)).monospacedDigit()
                                .frame(width: 70, alignment: .leading)
                        }
                        .help("\(r.name): resident \(Fmt.bytes(r.resident)) (dirty \(Fmt.bytes(r.dirty))), swapped \(Fmt.bytes(r.swapped)), virtual \(Fmt.bytes(r.virtual))")
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private var regionTable: some View {
        let rows = filteredRegions.sorted(using: regionSort)
        let maxRes = Double(rows.map(\.resident).max() ?? 1)
        let maxSwap = Double(rows.map(\.swapped).max() ?? 1)
        return Table(rows, sortOrder: $regionSort) {
            TableColumn("Region", value: \.name) { r in
                HStack {
                    Text(r.name)
                    if !r.note.isEmpty { Image(systemName: "info.circle").foregroundStyle(.secondary).help(r.note) }
                }
            }.width(min: 140, ideal: 220)
            TableColumn("Virtual", value: \.virtual) { r in Text(Fmt.bytes(r.virtual)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 70)
            TableColumn("Resident", value: \.resident) { r in
                HStack { MiniBar(fraction: Double(r.resident) / max(maxRes, 1), color: .blue, width: 50)
                    Text(Fmt.bytes(r.resident)).monospacedDigit() }
            }.width(min: 110, ideal: 130)
            TableColumn("Dirty", value: \.dirty) { r in Text(Fmt.bytes(r.dirty)).monospacedDigit().foregroundStyle(r.dirty > 0 ? .orange : .secondary) }
                .width(min: 60, ideal: 70)
            TableColumn("Swapped", value: \.swapped) { r in
                HStack { MiniBar(fraction: Double(r.swapped) / max(maxSwap, 1), color: .purple, width: 50)
                    Text(Fmt.bytes(r.swapped)).monospacedDigit() }
            }.width(min: 110, ideal: 130)
            TableColumn("Count", value: \.count) { r in Text(verbatim: "\(r.count)").monospacedDigit() }.width(min: 40, ideal: 50)
        }
    }

    private var zoneTable: some View {
        let rows = s.zones.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.sorted(using: zoneSort)
        let maxAlloc = Double(rows.map(\.allocated).max() ?? 1)
        return Table(rows, sortOrder: $zoneSort) {
            TableColumn("Zone", value: \.name) { z in Text(z.name) }.width(min: 160, ideal: 240)
            TableColumn("Allocated", value: \.allocated) { z in
                HStack { MiniBar(fraction: Double(z.allocated) / max(maxAlloc, 1), color: .blue, width: 50)
                    Text(Fmt.bytes(z.allocated)).monospacedDigit() }
            }.width(min: 110, ideal: 130)
            TableColumn("Allocations", value: \.allocations) { z in Text(verbatim: z.allocations.formatted()).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Fragmentation", value: \.fragPercent) { z in
                HStack {
                    MiniBar(fraction: Double(z.fragPercent) / 100, color: z.fragPercent > 50 ? .red : .orange, width: 50)
                    Text(verbatim: "\(z.fragPercent)%").monospacedDigit()
                    Text(Fmt.bytes(z.fragSize)).foregroundStyle(.secondary).monospacedDigit()
                }
            }.width(min: 150, ideal: 170)
            TableColumn("Resident", value: \.resident) { z in Text(Fmt.bytes(z.resident)).monospacedDigit() }.width(min: 60, ideal: 70)
            TableColumn("Swapped", value: \.swapped) { z in Text(Fmt.bytes(z.swapped)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 70)
        }
    }
}

/// "Writable regions: Total=4.7G written=145.2M(3%) …" as a labelled stacked bar.
struct PortionBar: View {
    let title: String
    let total: UInt64?
    let parts: [(String, UInt64?, Int?)]
    private let palette: [Color] = [.blue, .orange, .purple, .gray, .teal]

    var body: some View {
        // Only the parts that partition the total (vmmap lists "written" as a superset of resident/swapped).
        let shown = parts.filter { $0.0 != "written" }
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                        Rectangle().fill(palette[i % palette.count].opacity(0.8))
                            .frame(width: max(1, g.size.width * Double(p.2 ?? 0) / 100))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .frame(width: 220, height: 6)
            HStack(spacing: 8) {
                Text(verbatim: Fmt.bytes(total)).font(.caption).bold()
                ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 3) {
                        Circle().fill(palette[i % palette.count]).frame(width: 6, height: 6)
                        Text(verbatim: "\(p.0.replacingOccurrences(of: "_", with: " ")) \(Fmt.bytes(p.1))").font(.caption)
                    }
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - sample (call tree)

private let idleLeaves: Set<String> = [
    "mach_msg2_trap", "mach_msg_trap", "__workq_kernreturn", "semaphore_wait_trap", "semaphore_timedwait_trap",
    "__psynch_cvwait", "__psynch_mutexwait", "__psynch_rw_rdlock", "__psynch_rw_wrlock", "kevent", "kevent64", "kevent_id",
    "kevent_qos", "__select", "__semwait_signal", "__ulock_wait", "__ulock_wait2", "__sigsuspend", "__wait4", "__accept",
    "poll", "read", "__recvfrom", "__recvmsg", "__pselect", "__sleep", "start_wqthread", "__workq_open",
]

extension CallNode {
    var isIdleLeaf: Bool { children.isEmpty && idleLeaves.contains(symbol) }
    /// Samples where this frame itself was on top of the stack.
    var selfCount: Int { max(0, count - children.map(\.count).reduce(0, +)) }
    func leaves() -> [CallNode] { children.isEmpty ? [self] : children.flatMap { $0.leaves() } }
    var busySamples: Int { leaves().filter { !$0.isIdleLeaf }.map(\.count).reduce(0, +) }
}

struct SampleView: View {
    let report: SampleReport
    let filter: String
    @State private var expanded: Set<Int>
    @State private var hideIdle: Bool

    init(report: SampleReport, filter: String) {
        self.report = report
        self.filter = filter
        // Busy threads open fully; threads that only sat in a wait are collapsed to their header.
        var open: Set<Int> = []
        func all(_ n: CallNode) { open.insert(n.id); n.children.forEach(all) }
        for t in report.threads where t.busySamples > 0 { all(t) }
        _expanded = State(initialValue: open)
        _hideIdle = State(initialValue: false)
    }

    private struct Row: Identifiable {
        let node: CallNode
        let depth: Int
        let total: Int
        var id: Int { node.id }
    }

    private var matches: Set<Int>? {
        guard !filter.isEmpty else { return nil }
        var keep: Set<Int> = []
        @discardableResult func walk(_ n: CallNode) -> Bool {
            var hit = n.symbol.localizedCaseInsensitiveContains(filter) || (n.library?.localizedCaseInsensitiveContains(filter) ?? false)
            for c in n.children where walk(c) { hit = true }
            if hit { keep.insert(n.id) }
            return hit
        }
        report.threads.forEach { walk($0) }
        return keep
    }

    private func rows(_ m: Set<Int>?) -> [Row] {
        var out: [Row] = []
        func walk(_ n: CallNode, _ d: Int, _ total: Int) {
            if let m, !m.contains(n.id) { return }
            out.append(Row(node: n, depth: d, total: total))
            if m != nil || expanded.contains(n.id) { n.children.forEach { walk($0, d + 1, total) } }
        }
        for t in report.threads where !(hideIdle && t.busySamples == 0) { walk(t, 0, max(t.count, 1)) }
        return out
    }

    var body: some View {
        let m = matches
        let busyThreads = report.threads.filter { $0.busySamples > 0 }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatTile(title: "Threads", value: "\(report.threads.count)", sub: "\(busyThreads) doing work")
                StatTile(title: "Samples / thread", value: "\(report.totalSamples)")
                if !report.topOfStack.isEmpty { heaviest }
                Spacer(minLength: 0)
            }
            .padding(8)
            HStack(spacing: 10) {
                Button("Expand all") { var s: Set<Int> = []; func a(_ n: CallNode) { s.insert(n.id); n.children.forEach(a) }; report.threads.forEach(a); expanded = s }
                Button("Collapse all") { expanded = [] }
                Toggle("Hide idle threads", isOn: $hideIdle).toggleStyle(.checkbox)
                Spacer()
                HStack(spacing: 4) { Circle().fill(.orange).frame(width: 6, height: 6); Text("on CPU") }
                HStack(spacing: 4) { Circle().fill(.gray.opacity(0.6)).frame(width: 6, height: 6); Text("waiting") }
            }
            .controlSize(.small).font(.caption)
            .padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(m)) { r in row(r) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var heaviest: some View {
        let top = report.topOfStack.prefix(4)
        let mx = Double(top.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Heaviest top-of-stack frames").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(top.enumerated()), id: \.offset) { _, f in
                HStack(spacing: 6) {
                    MiniBar(fraction: Double(f.count) / mx, color: idleLeaves.contains(f.symbol) ? .gray : .orange, width: 60)
                    Text(verbatim: "\(f.count)").font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                    Text(f.symbol).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    if let l = f.library { Text(l).font(.caption2).foregroundStyle(libColor(l)) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ r: Row) -> some View {
        let n = r.node
        let open = expanded.contains(n.id) || matches != nil
        let frac = Double(n.count) / Double(r.total)
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(r.depth) * 12, height: 1)
            Image(systemName: n.children.isEmpty ? "circle.fill" : (open ? "chevron.down" : "chevron.right"))
                .font(.system(size: n.children.isEmpty ? 4 : 9, weight: .bold))
                .foregroundStyle(n.children.isEmpty ? (n.isIdleLeaf ? Color.gray : Color.orange) : Color.secondary)
                .frame(width: 12)
            Text(verbatim: "\(n.count)").monospacedDigit().font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            MiniBar(fraction: frac, color: n.isThread ? .accentColor : (n.busySamples > 0 ? .orange : .gray), width: 44)
            if n.isThread {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text(n.symbol).bold().lineLimit(1)
                let busy = n.busySamples
                Pill(text: busy == 0 ? "idle" : String(format: "%.0f%% busy", 100 * Double(busy) / Double(max(n.count, 1))),
                     color: busy == 0 ? .secondary : .orange)
                if busy == 0, let leaf = n.leaves().max(by: { $0.count < $1.count }) {
                    Text("waiting in \(leaf.symbol)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(n.symbol).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(n.isIdleLeaf ? .secondary : .primary)
                if let l = n.library { Text(l).font(.system(size: 10)).foregroundStyle(libColor(l)) }
                if !n.children.isEmpty, n.selfCount > 0 {
                    Pill(text: "self \(n.selfCount)", color: .orange)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: n.isThread ? 24 : 18)
        .padding(.horizontal, 6)
        .background(n.isThread ? Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !n.children.isEmpty else { return }
            if expanded.contains(n.id) { expanded.remove(n.id); return }
            // Open the whole linear chain down to the next branch point (sample trees are mostly chains).
            var cur: CallNode? = n
            while let c = cur {
                expanded.insert(c.id)
                cur = c.children.count == 1 ? c.children[0] : nil
            }
        }
        .help("\(n.symbol)\(n.library.map { " (in \($0))" } ?? "") — \(n.count) samples")
    }
}

// MARK: - log

extension LogEntry.Level {
    var color: Color {
        switch self {
        case .fault: .purple
        case .error: .red
        case .default: .gray
        case .info: .blue
        case .debug: .mint
        case .activity: .teal
        }
    }
}

struct LogView: View {
    let entries: [LogEntry]
    let filter: String
    @State private var levels: Set<LogEntry.Level> = []

    var body: some View {
        let rows = entries.filter {
            (levels.isEmpty || levels.contains($0.level)) &&
            (filter.isEmpty || $0.message.localizedCaseInsensitiveContains(filter) || $0.subsystem.localizedCaseInsensitiveContains(filter))
        }
        let counts = Dictionary(grouping: entries, by: \.level).mapValues(\.count)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(LogEntry.Level.allCases.filter { counts[$0] != nil }, id: \.self) { l in
                    let on = levels.contains(l)
                    Button { if on { levels.remove(l) } else { levels.insert(l) } } label: {
                        HStack(spacing: 4) { Text(l.rawValue); Text(verbatim: "\(counts[l] ?? 0)").bold().monospacedDigit() }
                            .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 22)
                            .foregroundStyle(on ? .white : l.color)
                            .background(on ? AnyShapeStyle(l.color) : AnyShapeStyle(l.color.opacity(0.14)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(verbatim: "\(rows.count) of \(entries.count) events").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            histogram(rows).frame(height: 70).padding(.horizontal, 8).padding(.bottom, 6)
            Table(rows) {
                TableColumn("Time") { e in Text(e.time).monospacedDigit().foregroundStyle(.secondary) }.width(min: 80, ideal: 90, max: 110)
                TableColumn("Level") { e in Pill(text: e.level.rawValue, color: e.level.color) }.width(min: 54, ideal: 60, max: 70)
                TableColumn("Thread") { e in Text(e.thread).monospaced().foregroundStyle(.secondary) }.width(min: 50, ideal: 60, max: 80)
                TableColumn("Subsystem") { e in
                    let parts = e.subsystem.split(separator: ":", maxSplits: 1).map(String.init)
                    HStack(spacing: 4) {
                        if let s = parts.first { Text(s).foregroundStyle(libColor(s)) }
                        if parts.count > 1 { Pill(text: parts[1]) }
                    }
                    .lineLimit(1)
                }.width(min: 110, ideal: 170, max: 260)
                TableColumn("Message") { e in Text(e.message).lineLimit(2).help(e.message) }
            }
        }
    }

    /// Event-rate histogram: 60 time buckets, each a column stacked by level (severest on top).
    private func histogram(_ rows: [LogEntry]) -> some View {
        let dates = rows.compactMap(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return AnyView(Color.clear) }
        let nb = 60
        let step = max(hi.timeIntervalSince(lo), 1) / Double(nb)
        var bins = Array(repeating: [LogEntry.Level: Int](), count: nb)
        for e in rows { guard let d = e.date else { continue }
            bins[min(nb - 1, Int(d.timeIntervalSince(lo) / step))][e.level, default: 0] += 1 }
        let peak = max(bins.map { $0.values.reduce(0, +) }.max() ?? 1, 1)
        let order: [LogEntry.Level] = [.fault, .error, .activity, .info, .default, .debug]
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        return AnyView(VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 0) {
                Text(verbatim: "\(peak)").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    .frame(maxHeight: .infinity, alignment: .top)
                GeometryReader { g in
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(0..<nb, id: \.self) { i in
                            VStack(spacing: 0) {
                                ForEach(order, id: \.self) { l in
                                    if let n = bins[i][l] {
                                        Rectangle().fill(l.color.opacity(0.85)).frame(height: max(l == .fault || l == .error ? 2 : 0, g.size.height * Double(n) / Double(peak)))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .help("\(tf.string(from: lo.addingTimeInterval(Double(i) * step))): " +
                                  order.compactMap { l in bins[i][l].map { "\($0) \(l.rawValue.lowercased())" } }.joined(separator: ", "))
                        }
                    }
                    .frame(height: g.size.height, alignment: .bottom)
                }
                .padding(.leading, 6)
            }
            HStack {
                Text(tf.string(from: lo)); Spacer(); Text(tf.string(from: hi))
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 40)
        })
    }
}

// MARK: - launchctl print / procinfo tree

struct KVTreeContent: View {
    let nodes: [KVNode]
    let filter: String

    private func keep(_ n: KVNode) -> Bool {
        filter.isEmpty || n.key.localizedCaseInsensitiveContains(filter) || (n.value?.localizedCaseInsensitiveContains(filter) ?? false)
            || n.children.contains(where: keep)
    }

    var body: some View {
        let ns = nodes.filter(keep)
        let leaves = ns.filter(\.isLeaf)
        let branches = ns.filter { !$0.isLeaf }
        // Small blocks tile two-up; big ones (entitlements, endpoint lists) get the full width so a
        // tall card never stretches a grid row and leaves its neighbour's column empty.
        let small = branches.filter { size($0) <= 10 }
        let large = branches.filter { size($0) > 10 }
        VStack(alignment: .leading, spacing: 10) {
            if !leaves.isEmpty {
                Card(title: "Overview", systemImage: "list.bullet.rectangle") {
                    KVGrid(rows: leaves.map { ($0.key, $0.value ?? "") })
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(small) { card($0) }
            }
            ForEach(large) { card($0) }
        }
    }

    private func size(_ n: KVNode) -> Int { n.children.reduce(n.children.count) { $0 + size($1) } }

    private func card(_ b: KVNode) -> some View {
        Card(title: b.key, systemImage: icon(for: b.key), trailing: b.value ?? "\(b.children.count)") {
            Branch(node: b, filter: filter, keep: keep)
        }
    }

    private func icon(for key: String) -> String {
        let k = key.lowercased()
        if k.contains("environment") { return "leaf" }
        if k.contains("endpoint") || k.contains("port") { return "point.3.connected.trianglepath.dotted" }
        if k.contains("coalition") { return "square.stack.3d.up" }
        if k.contains("argument") { return "terminal" }
        if k.contains("entitle") || k.contains("code signing") { return "checkmark.seal" }
        if k.contains("audit") || k.contains("info") { return "info.circle" }
        if k.contains("semaphore") || k.contains("event") { return "bolt" }
        return "curlybraces"
    }

    struct Branch: View {
        let node: KVNode
        let filter: String
        let keep: (KVNode) -> Bool
        var body: some View {
            let kids = node.children.filter(keep)
            let leaves = kids.filter(\.isLeaf)
            VStack(alignment: .leading, spacing: 6) {
                if !leaves.isEmpty { KVGrid(rows: leaves.map { ($0.key, $0.value ?? "") }) }
                ForEach(kids.filter { !$0.isLeaf }) { c in
                    DisclosureGroup {
                        Branch(node: c, filter: filter, keep: keep).padding(.leading, 4)
                    } label: {
                        HStack {
                            Text(c.key).font(.system(.body, design: .monospaced))
                            if let v = c.value { Text(v).foregroundStyle(.secondary) }
                            Spacer()
                            Text(verbatim: "\(c.children.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct KVTreeView: View {
    let text: String
    let filter: String
    var body: some View {
        let nodes = LaunchctlParser.parse(text)
        if nodes.isEmpty {
            UnparsedNote(raw: text)
        } else {
            ScrollView { KVTreeContent(nodes: nodes, filter: filter).padding(10) }
        }
    }
}

// MARK: - LaunchServices record

struct LSRecordContent: View {
    let raw: String
    let filter: String
    var body: some View {
        let header = raw.split(separator: "\n").first.map(String.init) ?? ""
        let rows = LSRecordParser.rows(raw).filter {
            filter.isEmpty || $0.0.localizedCaseInsensitiveContains(filter) || $0.1.localizedCaseInsensitiveContains(filter)
        }
        let flags = rows.filter { $0.0 == "flag" }.map(\.1)
        Card(title: header.trimmingCharacters(in: .whitespaces).components(separatedBy: " ASN:").first ?? "",
             systemImage: "app.badge", trailing: header.components(separatedBy: " ").first { $0.hasPrefix("ASN:") }) {
            if !flags.isEmpty { FlowPills(items: flags, color: .orange) }
            KVGrid(rows: rows.filter { $0.0 != "flag" })
        }
    }
}

// MARK: - Entitlements

struct EntitlementsView: View {
    let xml: String?
    let filter: String

    var body: some View {
        let dict: [String: Any]? = xml.flatMap { $0.data(using: .utf8) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        if let dict, !dict.isEmpty {
            let keys = dict.keys.sorted().filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
            let groups: [(String, String, Color, [String])] = [
                ("Private (Apple-internal)", "lock.fill", .orange, keys.filter { $0.contains(".private.") || $0.hasPrefix("private.") }),
                ("Sandbox & security", "shield.lefthalf.filled", .blue, keys.filter { $0.hasPrefix("com.apple.security.") }),
                ("Other", "seal", .secondary, keys.filter { !$0.contains(".private.") && !$0.hasPrefix("private.") && !$0.hasPrefix("com.apple.security.") }),
            ]
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(groups, id: \.0) { g in
                            StatTile(title: g.0, value: "\(g.3.count)", color: g.3.isEmpty ? .secondary : g.2)
                        }
                        Spacer()
                    }
                    ForEach(groups.filter { !$0.3.isEmpty }, id: \.0) { g in
                        Card(title: g.0, systemImage: g.1, trailing: "\(g.3.count)") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(g.3, id: \.self) { k in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(k).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                        Spacer(minLength: 12)
                                        PlistValue(value: dict[k]!)
                                    }
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "seal").font(.largeTitle).foregroundStyle(.secondary)
                Text(xml == nil ? "No entitlements (or not yet loaded)." : "Entitlements could not be parsed — see Raw.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PlistValue: View {
    let value: Any
    var body: some View {
        if let b = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            Image(systemName: b ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(b ? .green : .red)
        } else if let s = value as? String {
            Text(s).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        } else if let n = value as? NSNumber {
            Text(n.stringValue).monospacedDigit()
        } else if let a = value as? [Any] {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(Array(a.enumerated()), id: \.offset) { _, v in
                    if let s = v as? String { Pill(text: s, color: .accentColor) } else { PlistValue(value: v) }
                }
            }
        } else if let d = value as? [String: Any] {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(d.keys.sorted(), id: \.self) { k in
                    HStack { Text(k).font(.caption).foregroundStyle(.secondary); PlistValue(value: d[k]!) }
                }
            }
        } else if let data = value as? Data {
            Text("\(data.count) bytes").foregroundStyle(.secondary)
        } else {
            Text(String(describing: value)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Args & environment

struct ArgsEnvView: View {
    let info: Native.ArgsEnv
    let filter: String

    var body: some View {
        let env = info.env.sorted().compactMap { e -> (String, String)? in
            guard let eq = e.firstIndex(of: "=") else { return (e, "") }
            return (String(e[..<eq]), String(e[e.index(after: eq)...]))
        }.filter { filter.isEmpty || $0.0.localizedCaseInsensitiveContains(filter) || $0.1.localizedCaseInsensitiveContains(filter) }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Card(title: "Executable", systemImage: "terminal") {
                    Text(info.execPath).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Card(title: "Arguments", systemImage: "list.number", trailing: "\(info.args.count)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(info.args.enumerated()), id: \.offset) { i, a in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "\(i)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                Text(a).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    .foregroundStyle(a.hasPrefix("-") ? Color.accentColor : .primary)
                            }
                        }
                    }
                }
                Card(title: "Environment", systemImage: "leaf", trailing: "\(env.count)") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(Array(env.enumerated()), id: \.offset) { _, kv in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(kv.0).font(.system(.body, design: .monospaced)).bold().gridColumnAlignment(.trailing)
                                EnvValue(key: kv.0, value: kv.1)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

struct EnvValue: View {
    let key: String
    let value: String
    var body: some View {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.allSatisfy({ $0.hasPrefix("/") || $0.isEmpty }) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Label(p, systemImage: "folder").font(.system(.body, design: .monospaced)).labelStyle(.titleAndIcon)
                }
            }
            .textSelection(.enabled)
        } else {
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
