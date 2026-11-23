import Foundation

/// Decides when the reading surface should scroll and by how much. Pure math
/// shared by the reader window, PDFs, and external windows; all inputs are
/// top-down distances from the top of the visible area (y grows downward).
enum AutoScrollPlanner {
    static let triggerFraction: CGFloat = 2.0 / 3.0
    static let targetFraction: CGFloat = 1.0 / 3.0

    /// Scroll-down pixels that put the sentence's top about a third from the
    /// top of the viewport, or nil when it already sits high enough.
    static func scrollDownPixels(
        sentenceTop: CGFloat,
        sentenceBottom: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat? {
        guard viewportHeight > 0 else { return nil }
        guard sentenceBottom > viewportHeight * triggerFraction else { return nil }
        let excess = sentenceTop - viewportHeight * targetFraction
        return max(0, excess)
    }
}
