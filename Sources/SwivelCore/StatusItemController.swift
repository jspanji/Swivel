import AppKit
import SwiftUI

/// Owns the status item's click handling and the translucent NSPopover
/// that replaced the old NSMenu. AppDelegate keeps creating the
/// `NSStatusItem` itself (the custom-drawn icon, pulse animation, and
/// switching-feedback code all live there); this controller takes over
/// the button's target/action.
///
/// Left-click toggles the SwiftUI popover. Right-click opens a minimal
/// fallback NSMenu (About / Check for Updates… / Quit) — muscle memory
/// for menu-bar users, and a guaranteed Quit path even if SwiftUI
/// rendering ever misbehaves.
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let fallbackMenu: NSMenu

    /// Watches for clicks in OTHER apps while the popover is open.
    /// `.transient` alone can't dismiss on those: Swivel is an accessory
    /// app that never activates, so a click elsewhere produces no
    /// deactivation signal for the popover to react to. A global monitor
    /// sees the click regardless of which app receives it.
    private var clickOutsideMonitor: Any?

    /// Behind-window glass installed under the popover's content. SwiftUI
    /// materials blend within-window only, which over the popover's own
    /// background reads as a flat tint; this blurs the actual desktop
    /// behind the popover.
    private lazy var glassView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }()

    /// Fired just before the popover appears — AppDelegate refreshes the
    /// view model and nudges the status checker here, the same job
    /// `menuWillOpen` did for the old menu.
    var onWillShow: (() -> Void)?

    init(
        statusItem: NSStatusItem,
        rootView: PopoverRootView,
        fallbackMenu: NSMenu
    ) {
        self.statusItem = statusItem
        self.fallbackMenu = fallbackMenu
        super.init()

        // animates=false: with .preferredContentSize sizing, the resize
        // that follows a row-count change would otherwise animate from
        // the stale size and flash a visible empty band.
        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.delegate = self

        fallbackMenu.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Close the popover if it's showing. Safe to call unconditionally —
    /// every UIActions intent runs through this before presenting a
    /// modal NSAlert (a transient popover would lose key status to the
    /// alert and dismiss mid-interaction anyway, taking the alert's
    /// anchor with it).
    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showFallbackMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            onWillShow?()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Key status lets the popover receive hover + menu clicks
            // immediately, without an extra activating click.
            let window = popover.contentViewController?.view.window
            window?.makeKey()
            // Clear initial keyboard focus so the first control (the header
            // save button) doesn't open ringed/"selected". SwiftUI assigns
            // first responder on the next runloop tick, so clear it after.
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
            // Belt-and-suspenders: popoverWillShow already tried, but if
            // it fired before the window existed this attempt catches it.
            installGlassBackground()
            installClickOutsideMonitor()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        installGlassBackground()
    }

    func popoverDidClose(_ notification: Notification) {
        // Single teardown point — covers click-outside, performClose
        // from UIActions, the toggle path, and escape.
        removeClickOutsideMonitor()
    }

    /// Slide the behind-window material between the popover frame's own
    /// background and our SwiftUI content. Subviews of the frame view
    /// render above its built-in drawing, so the glass fully replaces
    /// the default (mostly opaque) popover look while NSHostingController
    /// keeps owning the sizing.
    private func installGlassBackground() {
        guard let contentView = popover.contentViewController?.view,
              let frameView = contentView.window?.contentView?.superview,
              glassView.superview !== frameView
        else { return }
        glassView.frame = frameView.bounds
        glassView.autoresizingMask = [.width, .height]
        frameView.addSubview(glassView, positioned: .below, relativeTo: contentView)
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Standard non-deprecated trick for a secondary menu on an
    /// NSStatusItem: temporarily assign `menu` (which makes the next
    /// click open it), synthesize that click, then detach again in
    /// `menuDidClose` so subsequent left-clicks reach our action.
    private func showFallbackMenu() {
        closePopover()
        statusItem.menu = fallbackMenu
        statusItem.button?.performClick(nil)
    }

    // MARK: - NSMenuDelegate (fallback menu)

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}
