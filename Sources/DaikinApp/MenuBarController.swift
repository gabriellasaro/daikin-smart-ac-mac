import AppKit
import DaikinKit
import Observation
import SwiftUI

/// The menu bar item and the panel that drops from it.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra`. That scene's panel is a square, borderless
/// window with no way to shape it, and it is sized from a measurement that can disagree with the
/// content as laid out, which leaves see-through bands above and below. Here the panel is always
/// exactly as tall as its content, and its outline, blur and shadow all follow one mask.
@MainActor
final class MenuBarController: NSObject {
    static let panelWidth: CGFloat = 320
    /// Chosen by eye to sit with the system's own menu bar panels; the system exposes no value to read.
    static let cornerRadius: CGFloat = 20
    private static let gapBelowMenuBar: CGFloat = 6
    /// Longer than one click takes to do both of its jobs, shorter than a deliberate second click.
    private static let reopenGuard: TimeInterval = 0.3
    private static let screenMargin: CGFloat = 8

    private let store: DeviceStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuBarPanelWindow(cornerRadius: MenuBarController.cornerRadius)
    private var contentHeight: CGFloat = 0
    private var clickMonitors: [Any] = []
    /// When the panel last closed because something else took the click or the keyboard.
    private var dismissedAt: TimeInterval = 0

    /// Set by tests, to keep the panel up while the app is in the background.
    var staysOpen = false

    init(store: DeviceStore, loginItem: LoginItem, showMainWindow: @escaping @MainActor () -> Void) {
        self.store = store
        super.init()

        let content = MenuBarPanel(
            store: store, loginItem: loginItem,
            showWindow: { [weak self] in
                self?.close()
                showMainWindow()
            },
            heightChanged: { [weak self] height in
                self?.contentHeightChanged(height)
            })
        let hostingView = NSHostingView(rootView: content)
        // Only report an ideal size; the panel's frame is set here, not negotiated by constraints.
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.host(hostingView)
        panel.onCancel = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown])
            button.imagePosition = .imageLeading
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel)
        updateLabel()
    }

    /// The panel while it is on screen.
    var panelWindow: NSWindow? {
        panel.isVisible ? panel : nil
    }

    var statusItemWindow: NSWindow? {
        statusItem.button?.window
    }

    /// What a click on the item does.
    func pressItem() {
        statusItem.button?.performClick(nil)
    }

    // MARK: - Item

    /// Draws the item, and again whenever the state it shows changes: the icon tells on from off
    /// and the text is the room temperature.
    private func updateLabel() {
        withObservationTracking {
            let controller = store.controller
            let port = controller?.port
            let isReachable = port != nil && controller?.errorMessage == nil
            guard let button = statusItem.button else { return }

            let symbol = isReachable && port?.isOn == true
                ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Daikin")
            if isReachable, let room = port?.sensors?.roomTemp {
                button.title = "\(formatDegrees(room))°"
            } else {
                button.title = ""
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateLabel() }
        }
    }

    // MARK: - Panel

    /// A click on the item while the panel is up reaches here twice over: it first takes the
    /// keyboard from the panel, which dismisses it, and then arrives as the item's action. That
    /// action must not open the panel again, or the click meant to close it only makes it blink.
    @objc private func togglePanel() {
        if panel.isVisible {
            close()
        } else if ProcessInfo.processInfo.systemUptime - dismissedAt > Self.reopenGuard {
            show()
        }
    }

    func show() {
        // SwiftUI does not keep a hidden window laid out, so measure before showing.
        let fitting = panel.fittingContentHeight.rounded(.up)
        if fitting > 0 { contentHeight = fitting }
        positionPanel()
        // A non-activating panel takes the keyboard without bringing the whole app forward.
        panel.makeKeyAndOrderFront(nil)
        // AppKit clears the highlight when the click ends; put it back while the panel is up.
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            statusItem.button?.highlight(true)
        }
        // A click anywhere else dismisses the panel, as with the system's own: in another app
        // (the global monitor) or in another window of this one (the local monitor).
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            },
            NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                let windowNumber = event.windowNumber
                MainActor.assumeIsolated { self?.clicked(inWindow: windowNumber) }
                return event
            },
        ].compactMap { $0 }
    }

    /// Clicks in the panel are its own business, and one on the item is left to `togglePanel`.
    private func clicked(inWindow windowNumber: Int) {
        if windowNumber != panel.windowNumber, windowNumber != statusItem.button?.window?.windowNumber {
            dismiss()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    private func dismiss() {
        guard !staysOpen, panel.isVisible else { return }
        dismissedAt = ProcessInfo.processInfo.systemUptime
        close()
    }

    /// Covers clicks on this app's other windows and switching apps from the keyboard.
    @objc private func panelResignedKey() {
        dismiss()
    }

    /// Called from inside SwiftUI's layout pass, so the window is resized once that pass is over.
    private func contentHeightChanged(_ measured: CGFloat) {
        let height = measured.rounded(.up)
        guard height > 0, height != contentHeight else { return }
        contentHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            positionPanel()
        }
    }

    /// Under the item, kept on its screen, growing downwards from a fixed top edge.
    private func positionPanel() {
        guard let itemWindow = statusItem.button?.window else { return }
        let item = itemWindow.frame
        let visible = (itemWindow.screen ?? NSScreen.main)?.visibleFrame ?? item
        let width = Self.panelWidth
        let x = min(max(item.midX - width / 2, visible.minX + Self.screenMargin), visible.maxX - width - Self.screenMargin)
        let top = item.minY - Self.gapBelowMenuBar
        panel.setFrame(NSRect(x: x, y: top - contentHeight, width: width, height: contentHeight), display: true)
    }
}

/// A borderless panel with a blurred background and rounded corners.
final class MenuBarPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    private let background = NSVisualEffectView()
    private var hostedView: NSView?

    init(cornerRadius: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MenuBarController.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        // The mask shapes the blur, and AppKit takes the window's outline and shadow from it too.
        background.maskImage = Self.mask(radius: cornerRadius)
        // The mask does not clip subviews, so the content is clipped to the same curve.
        background.wantsLayer = true
        background.layer?.cornerRadius = cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        contentView = background
    }

    /// `view` always fills the panel; its content keeps itself at the top.
    func host(_ view: NSView) {
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        hostedView = view
    }

    /// The height the content asks for.
    var fittingContentHeight: CGFloat {
        hostedView?.fittingSize.height ?? 0
    }

    /// Borderless windows refuse the keyboard by default.
    override var canBecomeKey: Bool { true }

    /// Escape.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A rounded square that stretches from its centre, with continuous corners like the layer clip.
    private static func mask(radius: CGFloat) -> NSImage {
        let cap = (radius * 1.6).rounded(.up)
        let side = cap * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}
