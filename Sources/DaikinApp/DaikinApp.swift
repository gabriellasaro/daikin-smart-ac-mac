import AppKit
import DaikinKit
import SwiftUI

@main
struct DaikinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DeviceStore()
    @State private var loginItem = LoginItem()

    static let mainWindowID = "main"

    var body: some Scene {
        Window("Daikin", id: Self.mainWindowID) {
            RootView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Aparelho") {
                DeviceMenu(store: store)
            }
        }

        MenuBarExtra {
            MenuBarPanel(store: store, loginItem: loginItem)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run straight from `swift run`, there is no bundle to make this a regular app.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        #if DEBUG
        Snapshot.captureIfRequested()
        #endif
    }

    /// The app lives on in the menu bar after its window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon brings the closed window back; SwiftUI does not do it for a `Window` scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let mainWindow = sender.windows.first { $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        if let mainWindow, !mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
