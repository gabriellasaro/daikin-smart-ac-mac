import DaikinKit
import SwiftUI

struct RootView: View {
    @Environment(DeviceStore.self) private var store
    @State private var isAddingDevice = false

    var body: some View {
        Group {
            if let controller = store.controller {
                ControlView(controller: controller)
                    .navigationTitle(controller.device.name)
                    .navigationSubtitle(subtitle(for: controller))
            } else {
                VStack(spacing: 0) {
                    if let loadError = store.loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .padding([.horizontal, .top], 20)
                    }
                    SetupView(isDismissable: false)
                }
                .navigationTitle("Adicionar ar-condicionado")
            }
        }
        .frame(width: 380)
        .toolbar {
            if let controller = store.controller {
                ToolbarItemGroup {
                    if store.devices.count > 1 {
                        Picker("Aparelho", selection: store.selectedName) {
                            ForEach(store.devices, id: \.name) { device in
                                Text(device.name).tag(device.name)
                            }
                        }
                    }
                    Button("Atualizar", systemImage: "arrow.clockwise") {
                        Task { await controller.refresh() }
                    }
                    .help("Atualizar agora")
                    Button("Adicionar aparelho", systemImage: "plus") {
                        isAddingDevice = true
                    }
                    .help("Adicionar outro ar-condicionado")
                }
            }
        }
        .sheet(isPresented: $isAddingDevice) {
            SetupView()
                .frame(width: 400)
        }
    }

    private func subtitle(for controller: ACController) -> String {
        if controller.errorMessage != nil { return "Sem conexão" }
        if controller.port == nil { return "Conectando…" }
        return controller.device.host
    }
}
