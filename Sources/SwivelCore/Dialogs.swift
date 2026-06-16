import AppKit
import UserNotifications

/// Modal alerts + banner notifications — the app's UI-feedback primitives.
/// Pulled out of `AppDelegate` so the action handlers depend on a small,
/// stateless surface (and the god object loses ~60 lines of boilerplate).
/// All methods are main-thread, synchronous where they return a value.
enum Dialogs {
    static func alert(_ title: String, style: NSAlert.Style, detail: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func confirm(
        title: String,
        message: String,
        confirmTitle: String = "Continue"
    ) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: confirmTitle)
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    static func prompt(
        title: String,
        message: String,
        actionTitle: String = "Save",
        initialValue: String = ""
    ) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: actionTitle)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initialValue
        a.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        // Focus the field and select its contents so pressing Return commits
        // the edit and typing replaces the initial value.
        DispatchQueue.main.async { field.selectText(nil) }
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Post a banner via UserNotifications. Silently no-ops if the user
    /// denied permission or we're running unbundled (the OS refuses
    /// delivery). A fresh UUID identifier lets consecutive banners stack
    /// rather than replace each other.
    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
