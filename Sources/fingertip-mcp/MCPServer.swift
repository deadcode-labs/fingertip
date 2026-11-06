//
//  MCPServer.swift
//  fingertip-mcp
//
//  MCP transport over stdio: JSON-RPC 2.0, one message per line. No SDK in
//  between because the surface needed is small —`initialize`, `tools/list`,
//  `tools/call`, `ping`— and so the binary depends on nothing.
//
//  stdout belongs to the protocol: anything else written there breaks the
//  session. Diagnostics go to stderr, which Claude Code keeps in its log.
//

import FingertipCore
import Foundation

/// What a tool returns: content blocks and whether it was an error. A tool error
/// is not a JSON-RPC error: it goes in the result, so the model reads it and
/// corrects course.
struct ToolResult {
    var content: [[String: Any]]
    var isError = false
    /// MCP `structuredContent`, for clients that branch on fields instead of reading text.
    /// Errors only: on a success Claude Code shows it instead of the text.
    var structured: [String: Any]? = nil
    /// How a `run_instruction` ended (`goal_reached`, `needs_user`, `stopped`), for the status
    /// toast. Never sent to the client.
    var outcome: String? = nil

    static func text(_ text: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": text]])
    }

    /// The code and retry flag go in the text too: the model reads text, not `structuredContent`.
    static func error(_ failure: any FingertipError, appending extra: String? = nil) -> ToolResult {
        let message = failure.errorDescription ?? failure.code
        var text = "Error \(failure.code) · retry_safe: \(failure.retrySafe)\n\(message)"
        if let extra { text += "\n\n\(extra)" }
        return ToolResult(
            content: [["type": "text", "text": text]],
            isError: true,
            structured: ["error": ["code": failure.code, "retry_safe": failure.retrySafe, "message": message]]
        )
    }
}

struct Tool {
    var name: String
    var description: String
    /// JSON Schema properties of the arguments.
    var properties: [String: Any] = [:]
    var required: [String] = []
    var handler: ([String: Any]) async -> ToolResult

    var definition: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required]
        ]
    }
}

final class MCPServer {
    private static let fallbackProtocolVersion = "2025-06-18"

    private let name: String
    private let version: String
    private let instructions: String
    private let tools: [Tool]
    /// What a call is doing, in words, for the Fingertip app's status toast.
    private let status: (String, [String: Any]) -> String

    init(name: String, version: String, instructions: String, tools: [Tool],
         status: @escaping (String, [String: Any]) -> String) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.status = status
    }

    /// Handles one message at a time: a slow tool (a Jev run) delays the next
    /// ones, which is right on a single device.
    func serve() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.isEmpty else { continue }
                await handle(line)
            }
        } catch {
            log("stdin: \(error.localizedDescription)")
        }
    }

    private func handle(_ line: String) async {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON"]])
            return
        }
        let method = message["method"] as? String ?? ""
        // No id means a notification (`notifications/initialized`, cancellations): no reply.
        guard let id = message["id"] else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? Self.fallbackProtocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools.map(\.definition)])
        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                fail(id, code: -32602, "Unknown tool: \(toolName)")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let text = status(toolName, arguments)
            // The edge indicator marks fingertip acting: on for the call, off a while after the last.
            await ActivityBeacon.shared.beginActivity()
            await ActivityBeacon.shared.send(.status(text: text, state: .working))
            let result = await tool.handler(arguments)
            if let finished = Self.finished(text, result) { await ActivityBeacon.shared.send(finished) }
            await ActivityBeacon.shared.endActivity()
            var payload: [String: Any] = ["content": result.content, "isError": result.isError]
            if let structured = result.structured { payload["structuredContent"] = structured }
            reply(id, payload)
        default:
            fail(id, code: -32601, "Method not supported: \(method)")
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: Any, code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// A run that stopped for the user or reached its goal already told the toast why,
    /// with more detail than here, so it is left as is; one that ran out of steps says so.
    /// Anything else that went fine hands the toast back to "thinking".
    private static func finished(_ text: String, _ result: ToolResult) -> OverlayEvent? {
        let error = result.structured?["error"] as? [String: Any]
        if result.isError {
            let code = error?["code"] as? String ?? "error"
            return .status(text: "\(text) · \(code)", state: .failed)
        }
        switch result.outcome {
        case "goal_reached", "needs_user": return nil
        // Out of steps or interrupted: the instruction isn't done, so neither "thinking" nor a plain label.
        case "stopped": return .status(text: "Jev: stopped without finishing the instruction", state: .held)
        default: return .status(text: text, state: .done)
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            log("couldn't serialize the response")
            return
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("fingertip-mcp: \(message)\n".utf8))
}
