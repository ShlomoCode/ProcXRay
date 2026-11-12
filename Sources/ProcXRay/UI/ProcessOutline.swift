import AppKit
import SwiftUI

/// The process table, as a plain NSOutlineView.
///
/// SwiftUI's `Table` re-diffed every row on every refresh, hosted a SwiftUI view per cell, measured
/// automatic row heights, and had no way to start expanded or react to a double-click. This view
/// reuses one row object per id, reloads only the visible rows when the tree's shape is unchanged,
/// and uses fixed-height cells.
struct ProcessOutline: NSViewRepresentable {
    let store: Store
    let grouping: Grouping
    let filter: String
    @Binding var selection: ProcNode.ID?
    @Binding var sort: [KeyPathComparator<ProcNode>]
    let onOpen: (ProcInfo) -> Void
    let onSignal: (pid_t, Int32, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 18
        outline.intercellSpacing = NSSize(width: 6, height: 2)
        outline.style = .fullWidth
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 14
        for c in Column.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            col.minWidth = c.widths.min
            col.width = c.widths.ideal
            col.headerCell.alignment = c.numeric ? .right : .left
            if c.comparator(.forward) != nil {
                col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: true)
            }
            outline.addTableColumn(col)
            if c == .name { outline.outlineTableColumn = col }
        }
        outline.autosaveName = "ProcessOutline.columns"
        outline.autosaveTableColumns = true

        let co = context.coordinator
        co.outline = outline
        co.parent = self
        co.observeStore()
        outline.dataSource = co
        outline.delegate = co
        outline.target = co
        outline.doubleAction = #selector(Coordinator.openClicked)
        outline.onReturn = { [weak co] in co?.openSelected() }
        let menu = NSMenu()
        menu.delegate = co
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let co = context.coordinator
        co.parent = self
        co.apply()
    }

    // MARK: Columns

    enum Column: String, CaseIterable {
        case name, pid, cpu, mem, threads, user, responsible, coalition, jetsam, signer, disk, started, context

        var title: String {
            switch self {
            case .name: "Name"
            case .pid: "PID"
            case .cpu: "CPU %"
            case .mem: "Memory"
            case .threads: "Thr"
            case .user: "User"
            case .responsible: "Responsible"
            case .coalition: "Res. coal."
            case .jetsam: "Jetsam"
            case .signer: "Signer"
            case .disk: "Disk I/O"
            case .started: "Started"
            case .context: "Context"
            }
        }

        var widths: (min: CGFloat, ideal: CGFloat) {
            switch self {
            case .name: (180, 280)
            case .pid: (44, 56)
            case .cpu: (44, 52)
            case .mem: (60, 76)
            case .threads: (30, 36)
            case .user: (50, 70)
            case .responsible: (80, 130)
            case .coalition, .jetsam: (50, 64)
            case .signer: (70, 110)
            case .disk: (56, 70)
            case .started: (50, 70)
            case .context: (120, 300)
            }
        }

        var numeric: Bool { [.pid, .cpu, .mem, .threads, .coalition, .jetsam, .disk].contains(self) }

        func comparator(_ order: SortOrder) -> KeyPathComparator<ProcNode>? {
            switch self {
            case .name: KeyPathComparator(\.nameKey, order: order)
            case .pid: KeyPathComparator(\.pidKey, order: order)
            case .cpu: KeyPathComparator(\.cpuKey, order: order)
            case .mem: KeyPathComparator(\.memKey, order: order)
            case .threads: KeyPathComparator(\.threadsKey, order: order)
            case .user: KeyPathComparator(\.userKey, order: order)
            case .responsible: KeyPathComparator(\.respKey, order: order)
            case .coalition: KeyPathComparator(\.coalKey, order: order)
            case .jetsam: KeyPathComparator(\.jetsamKey, order: order)
            case .signer: KeyPathComparator(\.signerKey, order: order)
            case .disk: KeyPathComparator(\.diskKey, order: order)
            case .started: KeyPathComparator(\.startKey, order: order)
            case .context: nil
            }
        }
    }

    // MARK: Coordinator

    final class Item: NSObject {
        let id: Int
        var node: ProcNode
        var children: [Item] = []   // target, from the latest tree
        var shown: [Item] = []      // what the outline currently displays; the data source reads this
        init(_ node: ProcNode) { id = node.id; self.node = node }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessOutline!
        weak var outline: NSOutlineView?
        private var roots: [Item] = []
        private var byID: [Int: Item] = [:]
        private var appliedVersion = -1
        private var procs: [pid_t: ProcInfo] = [:]

        /// Re-apply whenever the store's process data changes, without going through SwiftUI.
        /// withObservationTracking fires once, before the change, so re-register and read after it lands.
        func observeStore() {
            guard let store = parent?.store else { return }
            withObservationTracking {
                _ = store.procs
                _ = store.lsApps
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apply()
                    self.observeStore()
                }
            }
        }
        private var collapsed: Set<Int> = []    // rows the user collapsed; everything else starts expanded
        private var updating = false
        private var pushedSort: [KeyPathComparator<ProcNode>] = []

        private var shownRoots: [Item] = []
        private var loaded = false

        func apply() {
            guard let outline else { return }
            updating = true
            defer { updating = false }
            syncSortIndicators(outline)
            let nodes = parent.store.nodes(grouping: parent.grouping, filter: parent.filter, sort: parent.sort)
            procs = parent.store.procs
            if parent.store.nodesVersion != appliedVersion {
                appliedVersion = parent.store.nodesVersion
                var seen: [Int: Item] = [:]
                func build(_ n: ProcNode) -> Item {
                    let it = byID[n.id] ?? Item(n)
                    it.node = n
                    seen[n.id] = it
                    it.children = (n.children ?? []).map(build)
                    return it
                }
                roots = nodes.map(build)
                byID = seen
                if !loaded {
                    loaded = true
                    func adopt(_ items: [Item]) { for it in items { it.shown = it.children; adopt(it.children) } }
                    adopt(roots)
                    shownRoots = roots
                    outline.reloadData()
                    expand(roots, in: outline)
                } else {
                    sync(outline)
                }
            }
            syncSelection(outline)
        }

        /// Brings the displayed tree to the target tree with per-parent removes, inserts and moves, then
        /// refreshes the values of the visible cells in place. No reloadData: existing cell views and
        /// expansion state survive, and only rows that actually changed position are touched.
        private func sync(_ outline: NSOutlineView) {
            // Keep the row at the top of the viewport where it is while rows come and go above it.
            let topRow = outline.row(at: NSPoint(x: 0, y: outline.visibleRect.minY + 1))
            let anchor = topRow >= 0 ? outline.item(atRow: topRow) as? Item : nil
            let anchorOffset = anchor == nil ? 0 : outline.rect(ofRow: topRow).minY - outline.visibleRect.minY

            var inserted: [Item] = []
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            outline.beginUpdates()
            // The outline calls back into the data source synchronously (e.g. from reloadItem), so the
            // displayed arrays are only ever touched in short, separate accesses: never held inout across
            // an outline call, which would be a Swift exclusivity violation (abort).
            func shown(_ p: Item?) -> [Item] { p?.shown ?? shownRoots }
            func edit(_ p: Item?, _ f: (inout [Item]) -> Void) {
                if let p { f(&p.shown) } else { f(&shownRoots) }
            }
            // Pass 1: removals everywhere first, so an item that changed parent is gone from its old
            // parent before it is inserted under the new one.
            func remove(_ p: Item?, target: [Item]) {
                let keep = Set(target.map(ObjectIdentifier.init))
                for i in shown(p).indices.reversed() where !keep.contains(ObjectIdentifier(shown(p)[i])) {
                    edit(p) { $0.remove(at: i) }
                    outline.removeItems(at: IndexSet(integer: i), inParent: p, withAnimation: [])
                }
                for c in shown(p) { remove(c, target: c.children) }
            }
            remove(nil, target: roots)
            // Pass 2: inserts and moves, top-down.
            var insertedIDs = Set<ObjectIdentifier>()
            func place(_ p: Item?, target: [Item]) {
                for (i, t) in target.enumerated() {
                    let cur = shown(p)
                    if i < cur.count, cur[i] === t { continue }
                    if let j = cur.firstIndex(where: { $0 === t }) {
                        edit(p) { $0.remove(at: j); $0.insert(t, at: i) }
                        outline.moveItem(at: j, inParent: p, to: i, inParent: p)
                    } else {
                        func adopt(_ it: Item) { it.shown = it.children; it.children.forEach(adopt) }
                        adopt(t)
                        edit(p) { $0.insert(t, at: i) }
                        outline.insertItems(at: IndexSet(integer: i), inParent: p, withAnimation: [])
                        inserted.append(t)
                        insertedIDs.insert(ObjectIdentifier(t))
                    }
                }
                for c in target where !insertedIDs.contains(ObjectIdentifier(c)) {
                    let wasLeaf = c.shown.isEmpty
                    place(c, target: c.children)
                    if wasLeaf != c.shown.isEmpty { outline.reloadItem(c, reloadChildren: false) }
                    if wasLeaf, !c.shown.isEmpty { inserted.append(c) }   // newly a parent: expand it
                }
            }
            place(nil, target: roots)
            outline.endUpdates()
            NSAnimationContext.endGrouping()
            expand(inserted, in: outline)

            if let anchor, let clip = outline.enclosingScrollView?.contentView, case let row = outline.row(forItem: anchor), row >= 0 {
                let y = outline.rect(ofRow: row).minY - anchorOffset
                if abs(y - clip.bounds.minY) > 0.5 {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(y, -clip.contentInsets.top)))
                    outline.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }

            // Values: update the visible cells in place.
            let visible = outline.rows(in: outline.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<visible.location + visible.length {
                guard let it = outline.item(atRow: row) as? Item else { continue }
                for col in 0..<outline.numberOfColumns {
                    if let cell = outline.view(atColumn: col, row: row, makeIfNecessary: false) as? Cell,
                       let c = Column(rawValue: outline.tableColumns[col].identifier.rawValue) {
                        cell.show(it.node, column: c, procs: procs)
                    }
                }
            }
        }

        /// Expands the given items and their descendants, except ones the user collapsed.
        private func expand(_ items: [Item], in outline: NSOutlineView) {
            for it in items where !it.shown.isEmpty {
                if collapsed.contains(it.id) { continue }
                outline.expandItem(it)
                expand(it.shown, in: outline)
            }
        }

        private func syncSelection(_ outline: NSOutlineView) {
            let current = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Item)?.id : nil
            guard current != parent.selection else { return }
            if let id = parent.selection, let it = byID[id] {
                // Programmatic jumps (Select Parent / Responsible) may target a row inside a collapsed group.
                var chain: [Item] = []
                var p = outline.parent(forItem: it) as? Item
                while let x = p { chain.append(x); p = outline.parent(forItem: x) as? Item }
                for x in chain.reversed() { collapsed.remove(x.id); outline.expandItem(x) }
                let row = outline.row(forItem: it)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else if parent.selection == nil {
                outline.deselectAll(nil)
            }
        }

        private func syncSortIndicators(_ outline: NSOutlineView) {
            guard parent.sort != pushedSort else { return }
            pushedSort = parent.sort
            outline.sortDescriptors = parent.sort.compactMap { c in
                Column.allCases.first { $0.comparator(.forward)?.keyPath == c.keyPath }
                    .map { NSSortDescriptor(key: $0.rawValue, ascending: c.order == .forward) }
            }
        }

        // MARK: Data source

        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.shown.count ?? shownRoots.count
        }
        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Item)?.shown[index] ?? shownRoots[index]
        }
        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Item)?.shown.isEmpty ?? true)
        }

        func outlineView(_ o: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard !updating else { return }
            let new: [KeyPathComparator<ProcNode>] = o.sortDescriptors.prefix(1).compactMap { d in
                Column(rawValue: d.key ?? "")?.comparator(d.ascending ? .forward : .reverse)
            }
            pushedSort = new
            parent.sort = new
        }

        // MARK: Delegate

        func outlineViewItemDidCollapse(_ n: Notification) {
            if !updating, let it = n.userInfo?["NSObject"] as? Item { collapsed.insert(it.id) }
        }
        func outlineViewItemDidExpand(_ n: Notification) {
            if !updating, let it = n.userInfo?["NSObject"] as? Item { collapsed.remove(it.id) }
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !updating, let o = outline else { return }
            let id = o.selectedRow >= 0 ? (o.item(atRow: o.selectedRow) as? Item)?.id : nil
            if id != parent.selection { parent.selection = id }
        }

        func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let col, let c = Column(rawValue: col.identifier.rawValue), let it = item as? Item else { return nil }
            let cell = (o.makeView(withIdentifier: col.identifier, owner: nil) as? Cell) ?? Cell(column: c)
            cell.show(it.node, column: c, procs: procs)
            return cell
        }

        // MARK: Actions

        @objc func openClicked() {
            guard let o = outline, o.clickedRow >= 0 else { return }
            open(o.item(atRow: o.clickedRow) as? Item)
        }

        func openSelected() {
            guard let o = outline, o.selectedRow >= 0 else { return }
            open(o.item(atRow: o.selectedRow) as? Item)
        }

        private func open(_ it: Item?) {
            guard let it, let o = outline else { return }
            if let p = it.node.proc { parent.onOpen(p); return }
            // Group rows toggle, like a disclosure triangle.
            if o.isItemExpanded(it) { o.collapseItem(it) } else { o.expandItem(it) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let o = outline, o.clickedRow >= 0, let p = (o.item(atRow: o.clickedRow) as? Item)?.node.proc else { return }
            let parent = self.parent!
            func add(_ title: String, _ action: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
                let a = MenuAction(action)
                mi.target = a
                mi.representedObject = a    // keeps the target alive while the menu is up
                menu.addItem(mi)
            }
            add("Properties") { parent.onOpen(p) }
            menu.addItem(.separator())
            add("Terminate (SIGTERM)") { parent.onSignal(p.pid, SIGTERM, "SIGTERM") }
            add("Kill (SIGKILL)") { parent.onSignal(p.pid, SIGKILL, "SIGKILL") }
            add("Suspend (SIGSTOP)") { parent.onSignal(p.pid, SIGSTOP, "SIGSTOP") }
            add("Resume (SIGCONT)") { _ = kill(p.pid, SIGCONT) }
            menu.addItem(.separator())
            if let path = p.path {
                add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                add("Copy Path") { Self.copy(path) }
            }
            add("Copy PID") { Self.copy("\(p.pid)") }
            if let r = p.responsible, r != p.pid, procs[r] != nil {
                add("Select Responsible (\(r))") { parent.selection = Int(r) }
            }
            if p.ppid > 1 { add("Select Parent (\(p.ppid))") { parent.selection = Int(p.ppid) } }
        }

        static func copy(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    final class MenuAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    /// Return opens the selected process, like a double-click.
    final class KeyOutlineView: NSOutlineView {
        var onReturn: (() -> Void)?
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 36 || e.keyCode == 76 { onReturn?() } else { super.keyDown(with: e) }
        }
    }

    // MARK: Cells

    final class Cell: NSTableCellView {
        private let label = NSTextField(labelWithString: "")
        private let icon = NSImageView()
        private static let mono = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        private static let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        private static let ghostIcon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        private static let groupIcon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        private static let terminalIcon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        /// Attributed strings carry their own paragraph style, which overrides the field's lineBreakMode.
        private static let truncating: NSParagraphStyle = {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
        }()

        init(column c: Column) {
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier(c.rawValue)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.truncatesLastVisibleLine = true
            label.alignment = c.numeric ? .right : .left
            label.font = c.numeric ? Self.mono : Self.body
            addSubview(label)
            textField = label
            hasIcon = c == .name
            if hasIcon {
                icon.imageScaling = .scaleProportionallyDown
                addSubview(icon)
                imageView = icon
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        // Frame layout, no constraints: with Auto Layout every value change re-ran the window's layout pass.
        private var hasIcon = false
        override func layout() {
            super.layout()
            let h = bounds.height, lh = ceil(Self.body.ascender - Self.body.descender + 2)
            var x: CGFloat = 2
            if hasIcon {
                icon.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16)
                x = 22
            }
            label.frame = NSRect(x: x, y: (h - lh) / 2, width: max(0, bounds.width - x - 2), height: lh)
        }

        // Assign only on change, so unchanged cells cause no redraw at all.
        private func set(_ v: String) { if label.stringValue != v { label.stringValue = v } }
        private func set(_ v: NSAttributedString) { if label.attributedStringValue != v { label.attributedStringValue = v } }
        private func set(color: NSColor) { if label.textColor != color { label.textColor = color } }
        private func set(image: NSImage?, tint: NSColor?) {
            if icon.image !== image { icon.image = image }
            if icon.contentTintColor != tint { icon.contentTintColor = tint }
        }

        func show(_ n: ProcNode, column c: Column, procs: [pid_t: ProcInfo]) {
            let p = n.proc
            var color = NSColor.labelColor
            switch c {
            case .name:
                showName(n, procs: procs)
                return
            case .pid: set(p.map { String($0.pid) } ?? "")
            case .cpu: set(Fmt.pct(p?.cpuPercent ?? (p == nil ? n.cpuKey : nil)))
            case .mem: set(p == nil ? Fmt.bytes(n.memKey) : Fmt.bytes(p?.footprint))
            case .threads: set(p?.threads.map(String.init) ?? "")
            case .user: set(p?.user ?? "")
            case .responsible:
                if let p, let r = p.responsible {
                    if r == p.pid { set("self"); color = .secondaryLabelColor }
                    else if let rp = procs[r] { set("\(rp.name) (\(r))") }
                    else { set("† gone (\(r))"); color = .systemOrange }
                } else { set("") }
            case .coalition: set(p?.coalition.map(String.init) ?? "")
            case .jetsam: set(p?.jetsamCoalition.map(String.init) ?? "")
            case .signer:
                set(p?.signer ?? "")
                if p?.signer == "unsigned" { color = .systemRed }
            case .disk: set(p.map { Fmt.bytes(($0.diskRead ?? 0) + ($0.diskWrite ?? 0)) } ?? "")
            case .started: set(p.map { Fmt.age($0.start) } ?? "")
            case .context:
                set(Self.context(n))
                color = .secondaryLabelColor
            }
            set(color: color)
        }

        private func showName(_ n: ProcNode, procs: [pid_t: ProcInfo]) {
            guard let p = n.proc else {
                set(image: n.isGhost ? Self.ghostIcon : Self.groupIcon, tint: n.isGhost ? .systemOrange : .secondaryLabelColor)
                set(NSAttributedString(string: n.title, attributes: [
                    .font: Self.bold, .foregroundColor: n.isGhost ? NSColor.systemOrange : NSColor.labelColor,
                    .paragraphStyle: Self.truncating,
                ]))
                return
            }
            set(image: IconCache.icon(for: p) ?? Self.terminalIcon, tint: nil)
            let orphan = p.responsible.map { $0 != p.pid && procs[$0] == nil } ?? false
            let color: NSColor = p.isZombie || !p.isInspectable ? .secondaryLabelColor : orphan ? .systemOrange : .labelColor
            let s = NSMutableAttributedString(string: n.title, attributes: [.font: Self.body, .foregroundColor: color])
            func badge(_ t: String, _ c: NSColor) {
                s.append(NSAttributedString(string: "  "))
                s.append(NSAttributedString(string: t, attributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: c,
                    .backgroundColor: c.withAlphaComponent(0.2), .baselineOffset: 1,
                ]))
            }
            if orphan { badge("LEFT", .systemOrange) }
            if p.isZombie { badge("ZOMBIE", .systemGray) }
            if p.isTranslated { badge("ROSETTA", .systemPurple) }
            if p.sandboxed == true { badge("SBX", .systemTeal) }
            if p.lsTags.contains(where: { $0.hasPrefix("exited") }) { badge("EXITED", .systemRed) }
            s.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: s.length))
            set(s)
        }

        static func context(_ n: ProcNode) -> String {
            guard let p = n.proc else { return n.subtitle }
            var parts: [String] = []
            if let l = p.launchdLabel { parts.append("launchd: \(l)") }
            if let a = p.lsAppName { parts.append("LS: \(a)") }
            if !p.lsTags.isEmpty { parts.append(p.lsTags.joined(separator: " ")) }
            if parts.isEmpty, let path = p.path { parts.append(path) }
            return parts.joined(separator: " · ")
        }
    }
}
