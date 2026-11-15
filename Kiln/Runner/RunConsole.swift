import Darwin
import Foundation
import Observation

/// Captures what a running app prints (stdout and stderr: print(), debugPrint(), fatalError messages)
/// while it runs inside Kiln, and still passes it on to Kiln's own output.
@MainActor
@Observable
final class RunConsole {
    static let shared = RunConsole()

    struct Line: Identifiable {
        let id: Int
        let text: String
        let date: Date
    }

    private(set) var lines: [Line] = []
    private(set) var isCapturing = false
    private var nextID = 0
    private var pending = ""

    @ObservationIgnored private var pipe: Pipe?
    @ObservationIgnored private var savedOut: Int32 = -1
    @ObservationIgnored private var savedErr: Int32 = -1

    /// Keeps memory bounded for apps that print a lot.
    private let maximumLines = 5000

    func start() {
        guard !isCapturing else { return }
        lines = []
        pending = ""
        let pipe = Pipe()
        fflush(stdout)
        fflush(stderr)
        savedOut = dup(STDOUT_FILENO)
        savedErr = dup(STDERR_FILENO)
        // print() buffers whole blocks when stdout is not a terminal; line buffering shows each line at once.
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let forward = savedOut
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if forward >= 0 {
                data.withUnsafeBytes { buffer in
                    _ = write(forward, buffer.baseAddress, buffer.count)
                }
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in RunConsole.shared.receive(text) }
        }
        self.pipe = pipe
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        fflush(stdout)
        fflush(stderr)
        if savedOut >= 0 { dup2(savedOut, STDOUT_FILENO); close(savedOut) }
        if savedErr >= 0 { dup2(savedErr, STDERR_FILENO); close(savedErr) }
        savedOut = -1
        savedErr = -1
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForWriting.close()
        pipe = nil
        isCapturing = false
        if !pending.isEmpty {
            append(pending)
            pending = ""
        }
    }

    func clear() {
        lines = []
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    private func receive(_ chunk: String) {
        let combined = pending + chunk
        var parts = combined.components(separatedBy: "\n")
        pending = parts.removeLast()
        parts.forEach(append)
    }

    private func append(_ text: String) {
        lines.append(Line(id: nextID, text: text, date: Date()))
        nextID += 1
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }
}
