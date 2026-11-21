import AppKit
import DaikinKit
import SwiftUI

/// What sits in the menu bar: an icon that tells on from off, and the room temperature.
struct MenuBarLabel: View {
    let store: DeviceStore

    var body: some View {
        let controller = store.controller
        let port = controller?.port
        let isReachable = port != nil && controller?.errorMessage == nil

        Image(systemName: isReachable && port?.isOn == true
            ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal")
            .accessibilityLabel("Daikin")
        if isReachable, let room = port?.sensors?.roomTemp {
            Text("\(formatDegrees(room))°")
        }
    }
}

/// The panel that drops from the menu bar item: the window's controls, laid out tighter.
struct MenuBarPanel: View {
    let store: DeviceStore
    let loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let controller = store.controller {
                ControlView(controller: controller)
                    .environment(\.isCompact, true)
            } else {
                VStack(spacing: 10) {
                    Text("Nenhum ar-condicionado salvo.")
                        .foregroundStyle(.secondary)
                    Button("Adicionar…", action: showWindow)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .modifier(PanelShape(radius: Self.cornerRadius))
    }

    /// Chosen by eye to sit with the system's own menu bar panels; the system exposes no value to read.
    static let cornerRadius: CGFloat = 20

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.controller?.device.name ?? "Daikin")
                    .font(.headline)
                if let controller = store.controller {
                    Text(controller.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.devices.count > 1 {
                Picker("Aparelho", selection: store.selectedName) {
                    ForEach(store.devices, id: \.name) { device in
                        Text(device.name).tag(device.name)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Abrir janela", action: showWindow)
                Spacer()
                Menu {
                    if loginItem.isAvailable {
                        Toggle("Abrir ao iniciar sessão", isOn: Binding {
                            loginItem.isEnabled
                        } set: { enabled in
                            loginItem.set(enabled)
                        })
                        Divider()
                    }
                    Button("Encerrar Daikin") {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Mais opções")
            }
            if let message = loginItem.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func showWindow() {
        openWindow(id: DaikinApp.mainWindowID)
        NSApp.activate()
    }
}

/// Gives the panel its rounded outline.
private struct PanelShape: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.background(WindowCorners(radius: radius))
    }
}

/// Rounds the corners of the window it sits in.
///
/// SwiftUI builds the menu bar panel as a borderless window, which the system leaves with square
/// corners. Two things have to change: the content is clipped by rounding the frame view's layer,
/// and the window server, which draws the shadow from the window's shape rather than from what is
/// drawn in it, is told the shape through AppKit's corner mask.
private struct WindowCorners: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSView {
        Probe(radius: radius)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        private let radius: CGFloat

        init(radius: CGFloat) {
            self.radius = radius
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not used from a nib")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let frameView = window.contentView?.superview else { return }
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = radius
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
            CornerMask.install(on: window, radius: radius)
            window.invalidateShadow()
        }

        /// The panel grows and shrinks with its content, and the shadow has to follow.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateShadow()
        }
    }
}

/// Answers AppKit's private `-[NSWindow _cornerMask]` for the panel's window class.
///
/// There is no public way to give a borderless window a rounded shape. AppKit asks the window for
/// a stretchable mask image and hands it to the window server; adding that method to SwiftUI's
/// panel class is the smallest hook that works. If a future macOS stops asking, nothing breaks:
/// the shadow just goes back to following the square frame.
@MainActor
private enum CornerMask {
    private static var installed: Set<ObjectIdentifier> = []

    static func install(on window: NSWindow, radius: CGFloat) {
        guard let windowClass = object_getClass(window), installed.insert(ObjectIdentifier(windowClass)).inserted else {
            return
        }
        let mask = image(radius: radius)
        let block: @convention(block) (AnyObject) -> NSImage = { _ in mask }
        let selector = NSSelectorFromString("_cornerMask")
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(windowClass, selector, implementation, "@@:"),
           let method = class_getInstanceMethod(windowClass, selector) {
            method_setImplementation(method, implementation)
        }
    }

    /// A rounded square that stretches from its centre, with the same continuous corners as the clip.
    private static func image(radius: CGFloat) -> NSImage {
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
