import AppKit
import ApplicationServices

/// Scrolls external windows with synthesized wheel events, the only way to
/// move a surface the app does not own. Accessibility must be granted;
/// without it tracking and highlights keep working and the app explains.
enum AutoScroller {
    static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Posts a smooth downward scroll of `pixels` to the app owning the
    /// reading surface, in a few small ticks so apps animate it naturally.
    /// shortcut: wheel events land in the app's key window — if the picked
    /// window is not key, the wrong window scrolls; wire AX-driven per-window
    /// scrolling if that bites.
    @MainActor
    static func scroll(downPixels: CGFloat, pid: pid_t) {
        guard pid > 0, downPixels > 0 else { return }
        let ticks = 6
        let perTick = downPixels / CGFloat(ticks)
        let source = CGEventSource(stateID: .combinedSessionState)

        Task { @MainActor in
            for _ in 0..<ticks {
                // Negative vertical delta scrolls toward later content.
                let event = CGEvent(
                    scrollWheelEvent2Source: source,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: -Int32(perTick.rounded()),
                    wheel2: 0,
                    wheel3: 0
                )
                event?.postToPid(pid)
                try? await Task.sleep(for: .milliseconds(18))
            }
        }
    }
}
