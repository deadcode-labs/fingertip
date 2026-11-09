//
//  DiagnosticsReporter.swift
//  Fingertip
//
//  Crash, hang and resource diagnostics through MetricKit. macOS delivers them
//  at most once a day, on a later launch than the one that hit them; each
//  payload is kept as JSON in ~/Library/Application Support/Fingertip/diagnostics/.
//  Nothing leaves the Mac.
//

import Foundation
import MetricKit

final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsReporter()

    nonisolated static let directory = URL.applicationSupportDirectory
        .appending(path: "Fingertip/diagnostics", directoryHint: .isDirectory)

    private override init() {
        super.init()
        MXMetricManager.shared.add(self)
        // Payloads delivered before this launch subscribed are not replayed through the delegate.
        Self.save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    // MetricKit calls this on a background queue.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.save(payloads)
    }

    private nonisolated static func save(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for payload in payloads {
                let stamp = payload.timeStampEnd.ISO8601Format().replacing(":", with: "-")
                let file = directory.appending(path: "\(stamp).json")
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                try payload.jsonRepresentation().write(to: file, options: .atomic)
            }
        } catch {
            FileHandle.standardError.write(Data("diagnostics: couldn't save a MetricKit payload: \(error.localizedDescription)\n".utf8))
        }
    }
}
