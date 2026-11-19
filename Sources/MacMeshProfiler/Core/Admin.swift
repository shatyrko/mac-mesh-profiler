import Foundation

enum AdminError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled — the administrator password was not entered."
        case .failed(let message): return message
        }
    }
}

/// Runs shell scripts as root through the standard macOS administrator prompt
/// (`do shell script … with administrator privileges`).
///
/// The script is base64-encoded before it is handed to AppleScript, so no
/// quoting or escaping of its contents is ever needed, and nothing is written
/// to a user-writable temp file that could be swapped before root runs it.
/// It runs in-process, so macOS reuses the authorization for a few minutes
/// and back-to-back actions usually ask for the password only once.
@MainActor
enum Admin {
    @discardableResult
    static func run(_ script: String, reason: String) async throws -> String {
        // Let SwiftUI paint the "busy" state before the modal prompt appears.
        await Task.yield()
        return try execute(appleScriptSource(script, reason: reason, privileged: true))
    }

    /// Escapes text for use inside an AppleScript "…" string literal.
    static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Builds the AppleScript source. `privileged: false` produces the same
    /// script without the admin prompt, which is what the self-test runs.
    static func appleScriptSource(_ script: String, reason: String, privileged: Bool) -> String {
        let wrapped = "set -e\n" + script
        let b64 = Data(wrapped.utf8).base64EncodedString()
        let command = "/bin/sh -c \"$(/bin/echo \(b64) | /usr/bin/base64 -D)\" 2>&1"
        let prompt = "Mac Mesh Profiler needs administrator access to \(reason)."
        var source = "do shell script \(appleScriptLiteral(command))"
        if privileged {
            source += " with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
        }
        return source + " without altering line endings"
    }

    static func execute(_ source: String) throws -> String {
        guard let appleScript = NSAppleScript(source: source) else {
            throw AdminError.failed("Could not build the privileged script.")
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -128 { throw AdminError.cancelled }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error (\(number))"
            throw AdminError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stringValue ?? ""
    }
}
