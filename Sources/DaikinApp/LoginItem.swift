import Foundation
import Observation
import ServiceManagement

/// "Open at login", through the system's login items. Only the user's own toggle changes it.
@MainActor @Observable
final class LoginItem {
    private(set) var isEnabled: Bool
    /// Why the last change did not take effect, or what the user still has to do.
    private(set) var message: String?

    /// Login items belong to app bundles; a bare `swift run` binary has none to register.
    let isAvailable = Bundle.main.bundleIdentifier != nil

    init() {
        isEnabled = isAvailable && SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = "Não foi possível alterar a abertura no login: \(error.localizedDescription)"
        }

        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        if enabled, status == .requiresApproval {
            message = "Falta aprovar em Ajustes do Sistema → Geral → Itens de Início."
        }
    }
}
