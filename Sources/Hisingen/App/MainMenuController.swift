import AppKit

/// Builds and installs the app's main menu — the menu-bar strip: the app menu ("Check for
/// Updates…", "Quit Hisingen") and a standard Edit menu.
///
/// A menu-bar-only agent still needs a real main menu so the standard Edit shortcuts
/// (⌘Z / ⌘X / ⌘C / ⌘V / ⌘A) reach the first responder in text fields. Extracted from
/// `AppDelegate.installMainMenu`; owns the `@objc` target for the "Check for Updates…" item.
@MainActor
final class MainMenuController: NSObject {
    private let onCheckForUpdates: () -> Void

    init(onCheckForUpdates: @escaping () -> Void) {
        self.onCheckForUpdates = onCheckForUpdates
        super.init()
    }

    func install() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let checkForUpdatesItem = appMenu.addItem(
            withTitle: L10n.text("Check for Updates…"),
            action: #selector(checkForUpdatesMenuItem), keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Quit Hisingen"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("Edit"))
        editMenu.addItem(withTitle: L10n.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func checkForUpdatesMenuItem() {
        onCheckForUpdates()
    }
}
