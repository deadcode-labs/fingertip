//
//  RunLog.swift
//  FingertipCore
//
//  Un archivo JSONL por corrida: una línea por paso, con lo que decidió Jev,
//  cuánto tardó y cuántos tokens costó. Al lado, una carpeta con el mismo
//  nombre guarda las capturas de pantalla de la corrida. Sirve para entender
//  una corrida después, no durante.
//

import CryptoKit
import Foundation

actor RunLog {
    /// `~/Library/Application Support/flowforge-jev/runs/<fecha>.jsonl`
    nonisolated let path: String
    private let url: URL
    /// `runs/<fecha>/`: las capturas de esta corrida.
    private let screenshots: URL
    /// Hash de cada captura ya guardada → su ruta. Comparar solo contra la
    /// última no alcanza: simctl a veces dibuja la Dynamic Island y a veces no
    /// sobre la misma pantalla, y eso solo generaría un archivo por segundo.
    private var saved: [SHA256.Digest: String] = [:]

    init() {
        let directory = FingertipSettings.load().effectiveRunsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Date.now.formatted(
            .verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                      locale: .current, timeZone: .current, calendar: .current)
        ).replacingOccurrences(of: ":", with: "-")

        url = directory.appending(path: "\(stamp).jsonl")
        path = url.path
        screenshots = directory.appending(path: stamp, directoryHint: .isDirectory)
    }

    /// Guarda la captura si es una imagen que esta corrida no vio todavía, y
    /// devuelve su ruta relativa al JSONL. Si ya la vio no escribe nada: devuelve
    /// la ruta existente con `isNew` en falso. simctl produce los mismos bytes
    /// para la misma pantalla, así que un hash alcanza.
    func saveScreenshot(_ png: Data) -> (name: String, isNew: Bool)? {
        let digest = SHA256.hash(data: png)
        if let existing = saved[digest] { return (existing, false) }

        try? FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let file = String(format: "%03d.png", saved.count + 1)
        guard (try? png.write(to: screenshots.appending(path: file))) != nil else { return nil }

        let name = "\(screenshots.lastPathComponent)/\(file)"
        saved[digest] = name
        return (name, true)
    }

    func append(_ entry: [String: Any]) {
        var line = entry
        line["at"] = Date.now.formatted(.iso8601)
        guard let data = try? JSONSerialization.data(
            withJSONObject: line,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
