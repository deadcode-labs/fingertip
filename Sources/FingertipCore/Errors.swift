//
//  Errors.swift
//  FingertipCore
//
//  Every error that reaches the app or the MCP carries a stable code and says
//  whether retrying is safe, so a caller can branch without parsing prose.
//

import Foundation

public nonisolated protocol FingertipError: LocalizedError, Sendable {
    /// Stable snake_case identifier.
    var code: String { get }
    /// Re-reading the screen and trying again cannot do harm and may succeed.
    var retrySafe: Bool { get }
}

/// Anything thrown by the system rather than by fingertip. Not known to be harmless to repeat.
public nonisolated struct UnexpectedError: FingertipError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var code: String { "unexpected" }
    public var retrySafe: Bool { false }
    public var errorDescription: String? { message }
}

public nonisolated func fingertipError(_ error: Error) -> any FingertipError {
    if let error = error as? any FingertipError { return error }
    return UnexpectedError(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
}

/// The caller acted on an element it saw in an earlier reading.
public nonisolated enum InspectorError: FingertipError {
    /// The reading is no longer kept, or never existed.
    case unknownReading(Int)
    case unknownAlias(alias: Int, reading: Int)
    /// Something up to and including the element changed, so its alias may point elsewhere.
    case screenChanged(caption: String, reading: Int, current: Int)
    /// The element has no driver alias, and the action has no point to fall back on.
    case noHandle(caption: String)

    public var code: String {
        switch self {
        case .unknownReading: "unknown_reading"
        case .unknownAlias: "unknown_alias"
        case .screenChanged: "screen_changed"
        case .noHandle: "no_handle"
        }
    }

    public var retrySafe: Bool { true }

    public var errorDescription: String? {
        switch self {
        case .unknownReading(let reading):
            "La lectura \(reading) ya no está: volvé a leer la pantalla y usá sus alias."
        case .unknownAlias(let alias, let reading):
            "No hay elemento @\(reading):\(alias) en la lectura \(reading)."
        case .screenChanged(let caption, let reading, let current):
            "No toqué «\(caption)»: la pantalla cambió entre la lectura \(reading) y la \(current), y su alias puede apuntar a otro elemento. Elegí de nuevo sobre la lectura actual."
        case .noHandle(let caption):
            "«\(caption)» no tiene alias del driver: solo se puede tocar por coordenadas."
        }
    }
}
