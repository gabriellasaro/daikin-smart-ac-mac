import AppKit
import DaikinKit
import SwiftUI

/// What the menu bar panel shows: the window's controls, laid out tighter.
struct MenuBarPanel: View {
    let store: DeviceStore
    let loginItem: LoginItem
    let showWindow: @MainActor () -> Void
    /// Reports the height the content takes, so the panel can be made exactly that tall.
    let heightChanged: @MainActor (CGFloat) -> Void

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
        .frame(width: MenuBarController.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            heightChanged(height)
        }
        // The hosting view is as big as the panel; while the panel catches up with a new height,
        // the content stays put at the top instead of drifting with the centre.
        .frame(maxHeight: .infinity, alignment: .top)
    }

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
                Button(action: showWindow) {
                    Text("Abrir janela")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.controlFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
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
}
