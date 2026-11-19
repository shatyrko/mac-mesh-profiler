import Foundation

struct DaemonStatus: Equatable {
    var plistInstalled = false
    var loaded = false
    var running = false
    var pid: Int?
    var lastExit: String?
    /// `launchctl disable` was used: launchd will not load it at boot.
    var disabledAtBoot = false

    var startsAtBoot: Bool { plistInstalled && !disabledAtBoot }
}

/// A root LaunchDaemon in the `system` launchd domain.
struct LaunchDaemon {
    let label: String
    let plistPath: String

    var target: String { "system/\(label)" }

    /// Reads state without root: `launchctl print` and `print-disabled` both work unprivileged.
    func status() async -> DaemonStatus {
        var s = DaemonStatus()
        s.plistInstalled = FileManager.default.fileExists(atPath: plistPath)

        let print = await Shell.run("/bin/launchctl", ["print", target])
        if print.ok {
            s.loaded = true
            // Only top-level keys (one tab deep): nested blocks such as
            // endpoints/event triggers have their own "state = active" lines.
            for raw in print.stdout.split(separator: "\n") {
                guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("state = ") {
                    s.running = line == "state = running"
                } else if line.hasPrefix("pid = "), let pid = Int(line.dropFirst(6)) {
                    s.pid = pid
                } else if line.hasPrefix("last exit code = ") {
                    s.lastExit = String(line.dropFirst("last exit code = ".count))
                }
            }
        }

        let disabled = await Shell.run("/bin/launchctl", ["print-disabled", "system"])
        let needle = "\"\(label)\" => "
        for raw in disabled.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(needle) {
                s.disabledAtBoot = line.hasSuffix("disabled") || line.hasSuffix("true")
            }
        }
        return s
    }

    // MARK: Root shell fragments (run through `Admin.run`)

    /// Loads (or restarts) the daemon. `keepBootSetting` re-applies "don't start at boot"
    /// after starting, because a disabled service can't be bootstrapped.
    func startScript(startAtBoot: Bool) -> String {
        """
        /bin/launchctl enable \(target)
        if /bin/launchctl print \(target) >/dev/null 2>&1; then
          /bin/launchctl kickstart -k \(target)
        else
          /bin/launchctl bootstrap system \(Shell.quote(plistPath))
        fi
        \(startAtBoot ? "" : "/bin/launchctl disable \(target)")
        """
    }

    func stopScript() -> String {
        """
        if /bin/launchctl print \(target) >/dev/null 2>&1; then
          /bin/launchctl bootout \(target) || true
        fi
        """
    }

    func restartScript() -> String {
        """
        if /bin/launchctl print \(target) >/dev/null 2>&1; then
          /bin/launchctl kickstart -k \(target)
        fi
        """
    }

    /// Restarts only if it is currently loaded; used after config changes.
    func restartIfLoadedScript() -> String { restartScript() }

    func bootSettingScript(enabled: Bool) -> String {
        "/bin/launchctl \(enabled ? "enable" : "disable") \(target)"
    }
}
