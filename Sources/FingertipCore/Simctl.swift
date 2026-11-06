//
//  Simctl.swift
//  FingertipCore
//
//  Wrapper sobre `xcrun simctl`: lifecycle del simulador y screenshots.
//  Each command runs with a deadline (`Subprocess`), so a stuck simctl cannot hang its caller.
//

import Foundation

public struct SimulatorDevice: Identifiable, Hashable, Sendable {
    public let udid: String
    public let name: String
    /// Runtime legible, derivado de la key del JSON: "iOS 27.0".
    public let runtime: String
    public let isBooted: Bool

    public var id: String { udid }
}

nonisolated enum SimctlError: FingertipError {
    case invalidUDID(String)
    case invalidBundleID(String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case badOutput(String)

    var code: String {
        switch self {
        case .invalidUDID: "invalid_udid"
        case .invalidBundleID: "invalid_bundle_id"
        case .commandFailed: "simctl_failed"
        case .badOutput: "simctl_bad_output"
        }
    }

    var retrySafe: Bool { false }

    var errorDescription: String? {
        switch self {
        case .invalidUDID(let udid):
            "Invalid UDID: \(udid)"
        case .invalidBundleID(let bundleID):
            "Invalid bundle id: \(bundleID)"
        case .commandFailed(let command, let status, let stderr):
            "`\(command)` failed (\(status)): \(stderr.isEmpty ? "no stderr" : stderr)"
        case .badOutput(let detail):
            "Unexpected output from simctl: \(detail)"
        }
    }
}

public actor Simctl {
    public init() {}

    private let udidPattern = #/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/#
    private let bundleIDPattern = #/^[A-Za-z0-9][A-Za-z0-9.-]*$/#
    private let runtimePattern = #/iOS-(\d+)-(\d+)$/#

    public func listDevices() async throws -> [SimulatorDevice] {
        let data = try await run(["simctl", "list", "devices", "--json"], isRead: true)
        let payload: DeviceList
        do {
            payload = try JSONDecoder().decode(DeviceList.self, from: data)
        } catch {
            throw SimctlError.badOutput(error.localizedDescription)
        }

        return payload.devices
            .compactMap { [runtimePattern] key, devices -> (String, [DeviceList.Device])? in
                guard let match = key.firstMatch(of: runtimePattern) else { return nil }
                return ("iOS \(match.1).\(match.2)", devices)
            }
            .flatMap { runtime, devices in
                devices.filter(\.isAvailable).map {
                    SimulatorDevice(
                        udid: $0.udid,
                        name: $0.name,
                        runtime: runtime,
                        isBooted: $0.state == "Booted"
                    )
                }
            }
            .sorted { ($0.runtime, $0.name) > ($1.runtime, $1.name) }
    }

    /// Bootea el simulador. Si ya está booteado, no hace nada.
    public func boot(udid: String) async throws {
        try validate(udid)
        do {
            _ = try await run(["simctl", "boot", udid], timeout: Self.bootTimeout)
        } catch SimctlError.commandFailed(_, _, let stderr) where stderr.contains("current state: Booted") {
            return
        }
    }

    /// Arranca la app bajo prueba. No hace nada especial si ya está corriendo.
    public func launch(bundleID: String, udid: String) async throws {
        try validate(udid)
        try validate(bundleID: bundleID)
        _ = try await run(["simctl", "launch", udid, bundleID])
    }

    /// Mata la app bajo prueba. Falla si no está corriendo — el caller decide si eso importa.
    public func terminate(bundleID: String, udid: String) async throws {
        try validate(udid)
        try validate(bundleID: bundleID)
        _ = try await run(["simctl", "terminate", udid, bundleID])
    }

    /// PNG de la pantalla actual. simctl solo escribe a archivo, así que pasa por temp.
    public func screenshot(udid: String) async throws -> Data {
        try validate(udid)
        let url = URL.temporaryDirectory.appending(path: "fingertip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await run(["simctl", "io", udid, "screenshot", "--type", "png", url.path], isRead: true)
        return try Data(contentsOf: url)
    }

    // MARK: - Proceso

    func validate(udid: String) throws { try validate(udid) }

    private func validate(_ udid: String) throws {
        guard udid.wholeMatch(of: udidPattern) != nil else {
            throw SimctlError.invalidUDID(udid)
        }
    }

    private func validate(bundleID: String) throws {
        guard bundleID.wholeMatch(of: bundleIDPattern) != nil else {
            throw SimctlError.invalidBundleID(bundleID)
        }
    }

    /// Long enough for any simctl call that is still making progress.
    private static let timeout: Duration = .seconds(60)
    /// Booting a cold simulator takes tens of seconds on its own.
    private static let bootTimeout: Duration = .seconds(180)

    /// `isRead`: the command changes nothing, so a timeout is safe to retry.
    @discardableResult
    private func run(_ arguments: [String], timeout: Duration = Simctl.timeout, isRead: Bool = false) async throws -> Data {
        let result = try await Subprocess.run(
            URL(filePath: "/usr/bin/xcrun"), arguments,
            label: "xcrun " + arguments.prefix(2).joined(separator: " "),
            timeout: timeout, isRead: isRead
        )
        guard result.status == 0 else {
            throw SimctlError.commandFailed(
                command: "xcrun \(arguments.joined(separator: " "))",
                status: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]

        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool
        }
    }
}
