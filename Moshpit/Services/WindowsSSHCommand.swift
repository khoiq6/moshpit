import Foundation

/// Device-local host metadata. Connections and credentials still use the
/// existing store/keychain; no secret is added to defaults.
enum WindowsHostPreferences {
    static func key(_ id: UUID) -> String { "workspace.windows.\(id.uuidString)" }
    static func isWindows(_ id: UUID) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }
    static func setWindows(_ value: Bool, id: UUID) {
        if value { UserDefaults.standard.set(true, forKey: key(id)) }
        else { UserDefaults.standard.removeObject(forKey: key(id)) }
    }
}

/// PowerShell -EncodedCommand takes UTF-16LE. This explicit envelope is
/// understood only by the borrowed SSH exec channel in the Rust core.
enum WindowsSSHCommand {
    private static let prefix = "@moshpit/ps-v1:"
    static func isEncoded(_ value: String) -> Bool { value.hasPrefix(prefix) }
    static func encode(_ script: String) -> String {
        let wrapped = "$ErrorActionPreference = 'Stop'; [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); " + script
        return prefix + (wrapped.data(using: .utf16LittleEndian)?.base64EncodedString() ?? "")
    }
}
