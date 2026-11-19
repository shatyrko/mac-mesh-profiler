import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

/// Runs unprivileged commands off the main thread.
enum Shell {
    static func run(_ executable: String, _ arguments: [String] = [], stdin: Data? = nil) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(executable, arguments, stdin: stdin))
            }
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], stdin: Data? = nil) -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(executable): not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin", "LANG": "en_US.UTF-8"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        do {
            try process.run()
        } catch {
            return ShellResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently so neither can fill up and block the child.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Single-quotes a string for safe interpolation into a /bin/sh script.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
