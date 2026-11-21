import DaikinKit
import SwiftUI

/// Adds a unit: finds it on the network, checks the Device Key against it and saves.
struct SetupView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// False when this is the first-run screen rather than a sheet, so there is nothing to cancel back to.
    var isDismissable = true

    @State private var found: [DiscoveredDevice] = []
    @State private var isSearching = false
    @State private var host = ""
    @State private var name = ""
    @State private var key = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    private var canConnect: Bool {
        !isConnecting && !host.trimmed.isEmpty && !key.trimmed.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SwiftUI.Section {
                    if found.count > 1 {
                        Picker("Encontrados na rede", selection: $host) {
                            ForEach(found, id: \.self) { device in
                                Text(device.hostname ?? device.name).tag(device.hostname ?? "")
                            }
                        }
                    }
                    TextField("Endereço", text: $host, prompt: Text("IP ou nome.local"))
                    TextField("Nome", text: $name, prompt: Text("Ar-condicionado"))
                } header: {
                    Text("Aparelho")
                } footer: {
                    searchStatus
                }

                SwiftUI.Section {
                    SecureField("Device Key", text: $key)
                } footer: {
                    Text("No app Daikin Smart AC do celular: Menu → Integrações → Home Assistant, selecione o SSID e toque em Enviar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                if isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                if isDismissable {
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Conectar") {
                    Task { await connect() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .task { await search() }
    }

    @ViewBuilder private var searchStatus: some View {
        Group {
            if isSearching {
                Text("Procurando na rede…")
            } else if found.isEmpty {
                HStack {
                    Text("Nenhum aparelho encontrado automaticamente.")
                    Button("Procurar de novo") {
                        Task { await search() }
                    }
                    .buttonStyle(.link)
                }
            } else if found.count == 1 {
                Text("Encontrado na rede.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func search() async {
        isSearching = true
        found = await Discovery.browse(for: 3).filter { $0.hostname != nil }
        isSearching = false
        if host.trimmed.isEmpty, let first = found.first?.hostname {
            host = first
        }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let host = host.trimmed
        let key = key.trimmed
        do {
            let client = try DaikinClient(host: host, keyBase64: key)
            _ = try await client.state()
            var apn = found.first { $0.hostname == host }?.apn
            if apn == nil { apn = try? await client.deviceInfo().apn }
            let name = name.trimmed.isEmpty ? defaultName : name.trimmed
            try store.save(DeviceConfig(name: name, host: host, apn: apn, key: key))
            if isDismissable { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var defaultName: String {
        store.devices.isEmpty ? "Ar-condicionado" : "Ar-condicionado \(store.devices.count + 1)"
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
