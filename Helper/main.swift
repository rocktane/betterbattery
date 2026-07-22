import Foundation
import Security

/// Privileged helper daemon entry point.
/// Registered by the app via SMAppService.daemon; launchd starts it on demand
/// when a client connects to the Mach service. Runs as root.

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isValidClient(connection) else {
            helperLog.error("Rejected XPC connection from unauthorized client")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService.shared
        connection.resume()
        return true
    }

    /// Validate the connecting process via its audit token (immune to PID
    /// reuse): it must be the BetterBattery app signed with our pinned
    /// certificate.
    private func isValidClient(_ connection: NSXPCConnection) -> Bool {
        // NSXPCConnection.auditToken is SPI; KVC access is the established
        // workaround (used by AlDente, Secretive, etc.)
        guard let tokenValue = connection.value(forKey: "auditToken") as? NSValue else {
            return false
        }
        var token = audit_token_t()
        tokenValue.getValue(&token)
        let tokenData = withUnsafeBytes(of: token) { Data($0) }

        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let clientCode = code else {
            return false
        }

        let requirementString =
            "identifier \"com.betterbattery.app\" and certificate leaf = H\"\(kPinnedCertSHA1)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [],
                                             &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }

        return SecCodeCheckValidity(clientCode, [], req) == errSecSuccess
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachService)
listener.delegate = delegate
listener.resume()
helperLog.info("BetterBattery helper v\(kHelperVersion) started, listening on \(kHelperMachService)")
RunLoop.main.run()
