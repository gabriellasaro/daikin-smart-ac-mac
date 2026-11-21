#if DEBUG
import AppKit
import DaikinKit

/// Development aid, debug builds only: `DAIKIN_SNAPSHOT=/path.png` drives the app from
/// environment variables, writes a picture of one of its windows and quits. It lets the
/// interface be checked, clicks included, without screen-recording or accessibility permission.
///
/// - `DAIKIN_SNAPSHOT_TARGET=window|panel|statusitem` picks what to capture: the main window
///   (default), the menu bar panel (opened for the occasion) or the menu bar item itself.
/// - `DAIKIN_SNAPSHOT_COMPOSITED=1` asks the window server for the picture instead of drawing the
///   views, which is the only way to see the window's real outline and shadow.
/// - `DAIKIN_SNAPSHOT_APPEARANCE=light|dark` forces an appearance.
/// - `DAIKIN_SNAPSHOT_DELAY` is how long to let the app settle before opening the panel,
///   pressing controls and taking the picture, in seconds (default 2).
/// - `DAIKIN_SNAPSHOT_CLOSE_WINDOW=1` closes the main window first.
/// - `DAIKIN_SNAPSHOT_REOPEN=1` then sends the event a click on the Dock icon sends.
/// - `DAIKIN_SNAPSHOT_OPEN_PANEL=1` opens the menu bar panel without capturing it.
/// - `DAIKIN_SNAPSHOT_MENU="Aparelho/Desligar,Aparelho/Modo/Ventilar"` clicks main menu items.
/// - `DAIKIN_SNAPSHOT_CLICK="window:336,130;panel:58,577"` clicks at points of the main window or
///   of the menu bar panel, measured from the top left of what a snapshot of it shows.
///
/// Menu items and clicks send real commands, so they are refused unless every saved device is
/// on localhost: point `DAIKIN_CONFIG` at a config for `Scripts/mock-device.py`.
@MainActor
enum Snapshot {
    static func captureIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DAIKIN_SNAPSHOT"] else { return }

        func list(_ name: String) -> [String] {
            environment[name]?.split(separator: ",").map(String.init) ?? []
        }
        let menuPaths = list("DAIKIN_SNAPSHOT_MENU")
        let clicks = (environment["DAIKIN_SNAPSHOT_CLICK"] ?? "").split(separator: ";").map(String.init)
        let target = environment["DAIKIN_SNAPSHOT_TARGET"] ?? "window"
        let delay = environment["DAIKIN_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2

        if !menuPaths.isEmpty || !clicks.isEmpty {
            let hosts = (try? Config.load().devices.map(\.host)) ?? []
            guard !hosts.isEmpty, hosts.allSatisfy({ $0 == "127.0.0.1" || $0 == "localhost" }) else {
                fail("scripted actions refused, saved devices are not all on localhost: \(hosts)", code: 3)
            }
        }
        switch environment["DAIKIN_SNAPSHOT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        Task { @MainActor in
            await pause(1)
            if environment["DAIKIN_SNAPSHOT_CLOSE_WINDOW"] != nil {
                mainWindow?.close()
                await pause(0.5)
            }
            if environment["DAIKIN_SNAPSHOT_REOPEN"] != nil {
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                do {
                    try event.sendEvent(options: .noReply, timeout: 1)
                } catch {
                    note("reopen event failed: \(error.localizedDescription)")
                }
                await pause(0.5)
            }
            if !menuPaths.isEmpty {
                // SwiftUI only enables its commands for the key window of the active app.
                NSApp.activate()
                mainWindow?.makeKeyAndOrderFront(nil)
                await pause(0.5)
                for menuPath in menuPaths {
                    click(menuPath: menuPath.split(separator: "/").map(String.init))
                }
            }
            await pause(delay)
            // The panel closes as soon as anything else takes focus, so it is opened last.
            if target == "panel" || environment["DAIKIN_SNAPSHOT_OPEN_PANEL"] != nil {
                await openPanel()
                await pause(0.5)
            }
            for click in clicks {
                self.click(at: click)
                await pause(0.4)
            }
            // Long enough for the debounced temperature command and the unit's reply.
            await pause(clicks.isEmpty ? 0.2 : 1.5)
            if environment["DAIKIN_SNAPSHOT_DEBUG"] != nil {
                note(windowListing)
                if let panel = panelWindow { describe(panel) }
            }
            capture(target, to: path)
        }
    }

    // MARK: - Windows

    private static var statusWindow: NSWindow? {
        NSApp.windows.first { $0.className.contains("StatusBar") }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== statusWindow && !($0 is NSPanel) }
    }

    private static var panelWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }
    }

    private static var windowListing: String {
        NSApp.windows.map {
            "\($0.className)(visible: \($0.isVisible), titled: \($0.styleMask.contains(.titled)), size: \(Int($0.frame.width))x\(Int($0.frame.height)))"
        }
            .joined(separator: ", ")
    }

    /// How a window is put together: its chrome settings, its view tree and the layers under it.
    private static func describe(_ window: NSWindow) {
        note("\(window.className) styleMask=\(window.styleMask.rawValue) opaque=\(window.isOpaque) "
            + "background=\(String(describing: window.backgroundColor)) shadow=\(window.hasShadow) "
            + "frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect)")
        func rect(_ r: CGRect) -> String {
            "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))"
        }
        func walkLayers(_ layer: CALayer, depth: Int, limit: Int) {
            guard depth < limit else { return }
            let fill = layer.backgroundColor.map { " fill=\($0.components ?? [])" } ?? ""
            note(String(repeating: "  ", count: depth + 1)
                + "· \(type(of: layer)) \(rect(layer.frame)) radius=\(layer.cornerRadius) masks=\(layer.masksToBounds)"
                + " mask=\(layer.mask != nil) opacity=\(layer.opacity)\(fill)")
            layer.sublayers?.forEach { walkLayers($0, depth: depth + 1, limit: limit) }
        }
        func walk(_ view: NSView, depth: Int) {
            guard depth < 3 else { return }
            note(String(repeating: "  ", count: depth + 1)
                + "\(view.className.prefix(60)) \(rect(view.frame)) safeArea=\(view.safeAreaInsets)")
            view.subviews.prefix(4).forEach { walk($0, depth: depth + 1) }
        }
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        walk(root, depth: 0)
        note("layers:")
        if let layer = root.layer { walkLayers(layer, depth: 0, limit: 5) }
    }

    // MARK: - Actions

    /// Clicks the menu bar item. There is one status window per menu bar (one per display),
    /// and only the one on the active display opens the panel, so each is tried in turn.
    private static func openPanel() async {
        func firstButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap(firstButton).first
        }
        let buttons = NSApp.windows
            .filter { $0.className.contains("StatusBar") }
            .compactMap { $0.contentView.flatMap(firstButton) }
        if buttons.isEmpty { note("no menu bar item — \(windowListing)") }

        // The panel closes itself unless the app is frontmost when it opens.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        for _ in 0..<20 where !NSApp.isActive {
            await pause(0.1)
        }
        if !NSApp.isActive { note("could not bring the app to the front") }
        for (index, button) in buttons.enumerated() {
            button.performClick(nil)
            for _ in 0..<10 where panelWindow == nil {
                await pause(0.1)
            }
            if panelWindow != nil { return }
            note("menu bar item \(index + 1) of \(buttons.count) did not open the panel")
        }
    }

    private static func click(menuPath: [String]) {
        var menu = NSApp.mainMenu
        for (depth, title) in menuPath.enumerated() {
            // SwiftUI fills its menus lazily, when AppKit is about to show them.
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
            menu?.update()
            guard let current = menu, let index = current.items.firstIndex(where: { $0.title == title }) else {
                note("no menu item \(menuPath.joined(separator: "/"))")
                return
            }
            if depth == menuPath.count - 1 {
                if !current.items[index].isEnabled {
                    let listing = current.items.map { "\($0.title)[\($0.isEnabled ? "on" : "off")]" }
                    note("menu item \(title) is disabled — \(listing.joined(separator: " "))")
                }
                current.performActionForItem(at: index)
            }
            menu = current.items[index].submenu
        }
    }

    /// `"window:x,y"` or `"panel:x,y"`: a left click at that point, counted from the top left.
    private static func click(at spec: String) {
        let parts = spec.split(separator: ":")
        let numbers = parts.last?.split(separator: ",").compactMap { Double($0) } ?? []
        guard parts.count == 2, numbers.count == 2 else {
            note("bad click \(spec)")
            return
        }
        guard let window = parts[0] == "panel" ? panelWindow : mainWindow else {
            note("no \(parts[0]) to click — \(windowListing)")
            return
        }
        let location = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Controls such as switches track the mouse in a nested loop: the release has to be
        // waiting in the queue before the press is delivered, or that loop never ends.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    // MARK: - Capture

    private static func capture(_ target: String, to path: String) {
        let window: NSWindow? = switch target {
        case "statusitem": statusWindow
        case "panel": panelWindow
        default: mainWindow
        }
        if ProcessInfo.processInfo.environment["DAIKIN_SNAPSHOT_COMPOSITED"] != nil {
            guard let window, let image = composited(window) else {
                fail("the window server gave no picture of \(target)", code: 1)
            }
            do {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            } catch {
                fail(error.localizedDescription, code: 1)
            }
            exit(0)
        }
        // The frame view carries the title bar of the main window and the corners of the panel.
        let view = target == "statusitem" ? window?.contentView : window?.contentView?.superview
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fail("nothing to capture for \(target) — \(windowListing)", code: 1)
        }
        if target == "statusitem", let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            // The item is drawn light on a transparent background; give it a menu bar to sit on.
            context.cgContext.setFillColor(NSColor.darkGray.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        }
        if target == "panel", let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            // Rendering the layer tree keeps the frame view's corner clipping, which `cacheDisplay` drops.
            // The panel's material is translucent and cannot be rendered this way, so it takes on the
            // backdrop painted here; a light one makes the cut-off corners easy to see.
            context.cgContext.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
            context.cgContext.fill(view.bounds)
            layer.render(in: context.cgContext)
        } else {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            fail(error.localizedDescription, code: 1)
        }
        exit(0)
    }

    /// One window of this app as the window server composites it, shadow included.
    ///
    /// `CGWindowListCreateImage` is gone from the SDK but still present at run time, and a process
    /// may always capture its own windows, so this needs no screen-recording permission.
    private static func composited(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let onlyThisWindow: UInt32 = 1 << 3
        let bestResolution: UInt32 = 1 << 3
        return createImage(.null, onlyThisWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        note(message)
        exit(code)
    }
}
#endif
