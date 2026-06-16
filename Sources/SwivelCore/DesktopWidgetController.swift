import AppKit
import Combine
import SwiftUI

/// Owns the floating glass desktop widget: a borderless non-activating
/// NSPanel hosting `WidgetRootView`. Not WidgetKit — Swivel is ad-hoc
/// signed, so a real widget extension would never be trusted by the
/// widget host. A panel gives the same always-on-desktop experience
/// (and more transparency control) within the existing build.
///
/// Two persisted bits of state besides the frame:
///   `showDesktopWidget`  — visibility, restored at launch
///   `widgetAlwaysOnTop`  — window level: desktop-adjacent vs floating
final class DesktopWidgetController {
    private static let visibleKey = "showDesktopWidget"
    private static let alwaysOnTopKey = "widgetAlwaysOnTop"
    private static let frameAutosaveName = "SwivelWidgetFrame"

    private let model: SwivelViewModel
    private var panel: NSPanel?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sizeSubscription: AnyCancellable?
    private let makeRootView: (DesktopWidgetController) -> WidgetRootView

    /// Called when the widget wants fresh data (timer tick, wake, show).
    var onRefreshNeeded: (() -> Void)?

    init(
        model: SwivelViewModel,
        makeRootView: @escaping (DesktopWidgetController) -> WidgetRootView
    ) {
        self.model = model
        self.makeRootView = makeRootView
        // Default to always-on-top: the widget earns its place as a
        // persistent HUD, so floating over your work is the point. Users
        // who'd rather tuck it behind windows can still flip it off.
        if UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) == nil {
            model.widgetAlwaysOnTop = true
        } else {
            model.widgetAlwaysOnTop = UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Restore the persisted visibility at launch.
    func restoreFromDefaults() {
        if UserDefaults.standard.bool(forKey: Self.visibleKey) {
            show()
        }
    }

    func toggle() {
        if model.widgetVisible {
            hide()
        } else {
            // Enabling from the menu always pins. An unpinned overlay opens
            // at desktop level — behind your windows — so it'd look like
            // nothing happened. Pinning guarantees it appears on top. (Users
            // can still unpin afterward; launch-restore respects that.)
            if !model.widgetAlwaysOnTop {
                model.widgetAlwaysOnTop = true
                UserDefaults.standard.set(true, forKey: Self.alwaysOnTopKey)
            }
            show()
        }
    }

    func show() {
        let panel = self.panel ?? buildPanel()
        self.panel = panel

        applyLevel(to: panel)
        clampToVisibleScreen(panel)
        panel.orderFrontRegardless()

        model.widgetVisible = true
        UserDefaults.standard.set(true, forKey: Self.visibleKey)

        onRefreshNeeded?()
        startRefreshTimer()
    }

    func hide() {
        panel?.orderOut(nil)
        model.widgetVisible = false
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
        stopRefreshTimer()
    }

    func toggleAlwaysOnTop() {
        model.widgetAlwaysOnTop.toggle()
        UserDefaults.standard.set(model.widgetAlwaysOnTop, forKey: Self.alwaysOnTopKey)
        if let panel { applyLevel(to: panel) }
    }

    // MARK: - Panel construction

    private func buildPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Survive Spaces switches and stay put during Mission Control;
        // never participate in ⌘` cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        // Behind-window glass: SwiftUI materials blend within-window, and
        // this panel's window is clear — there'd be nothing to blur. The
        // NSVisualEffectView blurs the actual desktop/wallpaper behind
        // the panel; the layer mask rounds the card.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: makeRootView(self))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass

        // Row count changes (add/delete account, usage line appearing)
        // change the card's intrinsic height; resize the panel to match
        // after SwiftUI has applied the new model.
        sizeSubscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak panel, weak hosting] _ in
                DispatchQueue.main.async {
                    guard let panel, let hosting, self?.model.widgetVisible == true else { return }
                    let size = hosting.fittingSize
                    if abs(panel.frame.height - size.height) > 0.5 {
                        var frame = panel.frame
                        // Keep the top edge anchored so growth extends
                        // downward rather than sliding the title bar.
                        frame.origin.y += frame.height - size.height
                        frame.size = size
                        panel.setFrame(frame, display: true)
                    }
                }
            }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.model.widgetVisible else { return }
            self.onRefreshNeeded?()
        }

        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    /// Desktop-adjacent by default: above wallpaper/desktop icons, below
    /// every app window — visible on show-desktop like a real widget.
    /// "Always on Top" flips to .floating for users who want it over
    /// their windows while they work.
    private func applyLevel(to panel: NSPanel) {
        if model.widgetAlwaysOnTop {
            panel.level = .floating
        } else {
            panel.level = NSWindow.Level(
                rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            )
        }
    }

    /// Frame autosave can restore a position on a display that's gone
    /// (unplugged monitor, resolution change). Pull the panel back onto
    /// the nearest visible screen.
    private func clampToVisibleScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame

        if frame.maxX < visible.minX + 40 { frame.origin.x = visible.minX + 20 }
        if frame.minX > visible.maxX - 40 { frame.origin.x = visible.maxX - frame.width - 20 }
        if frame.maxY < visible.minY + 40 { frame.origin.y = visible.minY + 20 }
        if frame.minY > visible.maxY - 40 { frame.origin.y = visible.maxY - frame.height - 20 }

        if frame != panel.frame {
            panel.setFrame(frame, display: false)
        }
    }

    // MARK: - Refresh cadence

    /// 60 s tick while visible. ProfileUsageReader's mtime cache makes a
    /// no-change tick nearly free, so this stays cheap; the payoff is
    /// the reset-countdown and freshness tags staying honest.
    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.onRefreshNeeded?()
        }
        timer.tolerance = 10
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
