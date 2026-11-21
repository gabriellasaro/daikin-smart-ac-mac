import AppKit
import DaikinKit
import SwiftUI

@main
struct DaikinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Daikin", id: "main") {
            RootView()
                .environment(appDelegate.store)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Aparelho") {
                DeviceMenu(store: appDelegate.store)
            }
        }
    }
}

/// Contents of the "Aparelho" menu, as a view so that its body tracks the unit's state.
private struct DeviceMenu: View {
    let store: DeviceStore

    var body: some View {
        let controller = store.controller
        let port = controller?.port
        let canSetTemperature = port?.isOn == true && controller?.temperatureRange != nil

        Button(port?.isOn == true ? "Desligar" : "Ligar") {
            controller?.setPower(port?.isOn != true)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(port == nil)

        Picker("Modo", selection: Binding<ACMode?> {
            port?.acMode
        } set: { mode in
            if let mode { controller?.setMode(mode) }
        }) {
            ForEach(controller?.availableModes ?? [], id: \.self) { mode in
                Text(mode.label).tag(ACMode?.some(mode))
            }
        }
        .disabled(port?.isOn != true)

        Divider()

        Button("Aumentar temperatura") { controller?.stepTemperature(by: 1) }
            .keyboardShortcut(.upArrow)
            .disabled(!canSetTemperature)
        Button("Diminuir temperatura") { controller?.stepTemperature(by: -1) }
            .keyboardShortcut(.downArrow)
            .disabled(!canSetTemperature)

        Divider()

        Button("Atualizar") {
            Task { await controller?.refresh() }
        }
        .keyboardShortcut("r")
        .disabled(controller == nil)
    }
}

/// Owns what outlives the window: the devices, and the menu bar item with its panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DeviceStore()
    private let loginItem = LoginItem()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run straight from `swift run`, there is no bundle to make this a regular app.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        let menuBar = MenuBarController(store: store, loginItem: loginItem) { [weak self] in
            self?.showMainWindow()
        }
        self.menuBar = menuBar
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        #if DEBUG
        Snapshot.captureIfRequested(menuBar: menuBar)
        #endif
    }

    /// The app lives on in the menu bar after its window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon brings the closed window back; SwiftUI does not do it for a `Window` scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if mainWindow?.isVisible != true { showMainWindow() }
        return true
    }

    /// With its window closed the app is only a menu bar item, and leaves the Dock.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// SwiftUI keeps the window object after it is closed, so it only has to be shown again.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && !($0 is NSPanel) && !$0.isSheet }
    }

    private func showMainWindow() {
        // Back in the Dock first: an accessory app cannot bring a window forward with its menus.
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
