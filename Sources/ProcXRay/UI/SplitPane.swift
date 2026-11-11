import AppKit
import SwiftUI

/// Vertical split whose divider position is a stored fraction of the available height.
/// Unlike VSplitView, swapping the bottom view (empty state ↔ inspector) never moves the divider,
/// because the layout depends only on the fraction, not on the children's ideal sizes.
struct SplitPane<Top: View, Bottom: View>: View {
    @AppStorage private var fraction: Double
    @State private var dragStartTop: CGFloat?
    private let minPane: CGFloat = 120
    private let top: Top
    private let bottom: Bottom

    init(id: String, defaultFraction: Double = 0.5, @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        _fraction = AppStorage(wrappedValue: defaultFraction, "splitPane.\(id)")
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let topHeight = clamp(total * fraction, total)
            VStack(spacing: 0) {
                top.frame(width: geo.size.width, height: topHeight)
                divider(total: total, topHeight: topHeight)
                bottom.frame(width: geo.size.width, height: max(0, total - topHeight - 1))
            }
        }
    }

    private func clamp(_ h: CGFloat, _ total: CGFloat) -> CGFloat {
        guard total > minPane * 2 else { return total / 2 }
        return min(max(h, minPane), total - minPane)
    }

    private func divider(total: CGFloat, topHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .overlay {
                // Larger invisible grab area centred on the 1pt line.
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = dragStartTop ?? topHeight
                                if dragStartTop == nil { dragStartTop = start }
                                fraction = Double(clamp(start + v.translation.height, total) / total)
                            }
                            .onEnded { _ in dragStartTop = nil }
                    )
            }
            .zIndex(1)
    }
}
