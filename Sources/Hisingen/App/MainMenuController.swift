import AppKit

/// Builds and installs the app's main menu – the menu-bar strip: the app menu ("Check for
/// Updates…", "Quit Hisingen") and a standard Edit menu.
///
/// A menu-bar-only agent still needs a real main menu so the standard Edit shortcuts
/// (⌘Z / ⌘X / ⌘C / ⌘V / ⌘A) reach the first responder in text fields. Extracted from
/// `AppDelegate.installMainMenu`; owns the `@objc` target for the "Check for Updates…" item.
@MainActor
final class MainMenuController: NSObject {
    private let onCheckForUpdates: () -> Void
    private let onOpenSettings: () -> Void

    init(onCheckForUpdates: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func install() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(
            withTitle: L10n.text("Settings…"),
            action: #selector(openSettingsMenuItem), keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
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

        // Services: without a real Services menu, text selected in a Settings field cannot be
        // handed to another app. The menu is empty until an app offers a service, which is the
        // standard behaviour — the point is that macOS has somewhere to put them.
        let servicesMenu = NSMenu(title: L10n.text("Services"))
        let servicesItem = NSMenuItem(title: L10n.text("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        mainMenu.addItem(servicesItem)

        // Window: the Settings window is the only one, but Minimize and Bring All to Front are
        // what a reader expects from a Mac app, and AppKit routes them without custom code.
        let windowMenu = NSMenu(title: L10n.text("Window"))
        windowMenu.addItem(withTitle: L10n.text("Minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.text("Bring All to Front"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: L10n.text("Window"), action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(windowItem)

        // Help: opens the published help page. A menu-bar app has no window to attach help to,
        // so the menu points at the documentation instead of inventing an in-app browser.
        let helpMenu = NSMenu(title: L10n.text("Help"))
        let helpItem = helpMenu.addItem(withTitle: L10n.text("Hisingen Help"),
                                        action: #selector(openHelp), keyEquivalent: "?")
        helpItem.target = self
        let helpMenuItem = NSMenuItem(title: L10n.text("Help"), action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openHelp() {
        guard let url = URL(string: "https://github.com/NicolasKheirallah/Hisingen/blob/main/docs/help.md") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettingsMenuItem() {
        onOpenSettings()
    }

    @objc private func checkForUpdatesMenuItem() {
        onCheckForUpdates()
    }
}
