/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Network
import Security

/// Loopback HTTP endpoint for Claude Code hook events (`POST /hook`). Bound to 127.0.0.1 on
/// a random port; every request must carry the per-launch secret from the hook's curl
/// config, and anything sent by a browser (an `Origin` header) is refused.
/// `PermissionRequest` responses are held open until the notch, the terminal, or the hook
/// process ends the request.
final class AIUsageHookServer {
    final class Responder {
        private let connection: NWConnection
        private let lock = NSLock()
        private var finished = false
        var onClientGone: (() -> Void)?

        init(connection: NWConnection) {
            self.connection = connection
        }

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        func respond(status: Int = 200, body: Data = Data()) {
            guard markFinished() else { return }
            let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
            var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            if !body.isEmpty { head += "Content-Type: application/json\r\n" }
            var payload = Data((head + "\r\n").utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }

        fileprivate func watchForDisconnect() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
                guard let self else { return }
                if isComplete || error != nil {
                    if self.markFinished() { self.onClientGone?() }
                    self.connection.cancel()
                } else if !self.isFinished {
                    self.watchForDisconnect()
                }
            }
        }

        private func markFinished() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    private let token: String
    private let queue = DispatchQueue(label: "com.ebullioscopic.Atoll.aiusage.hooks")
    private var listener: NWListener?
    private let onEvent: (AIUsageHookEvent, Responder) -> Void

    init(onEvent: @escaping (AIUsageHookEvent, Responder) -> Void) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        self.onEvent = onEvent
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, case .ready = state, let port = listener?.port?.rawValue else { return }
                try? AIUsageHookFiles.writeConfig(port: port, token: self.token)
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Logger.log("AI Usage hook server failed to start: \(error)", category: .warning)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AIUsageHookFiles.removeConfig()
    }

    private func accept(_ connection: NWConnection) {
        if case let .hostPort(host, _) = connection.endpoint {
            let peer = "\(host)".lowercased()
            guard peer.hasPrefix("127.") || peer == "::1" || peer.hasPrefix("::ffff:127.") else {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 2_000_000, error == nil else {
                connection.cancel()
                return
            }
            if let request = Self.parse(buffer) {
                self.dispatch(request, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func dispatch(_ request: (method: String, path: String, headers: [String: String], body: Data), connection: NWConnection) {
        let responder = Responder(connection: connection)
        guard request.method == "POST", request.path == "/hook",
              request.headers["origin"] == nil,
              Self.constantTimeEquals(request.headers["x-atoll-aiusage-token"] ?? "", token),
              let event = AIUsageHookEvent(json: request.body) else {
            responder.respond(status: 403)
            return
        }
        responder.watchForDisconnect()
        DispatchQueue.main.async { self.onEvent(event, responder) }
    }

    static func parse(_ buffer: Data) -> (method: String, path: String, headers: [String: String], body: Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        let path = requestLine[1].split(separator: "?").first.map(String.init) ?? "/"
        return (String(requestLine[0]), path, headers, buffer.subdata(in: end.upperBound..<(end.upperBound + length)))
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Claude Code permission requests waiting on the notch. A request ends when it is answered
/// in the notch, when Claude Code moves on (answered in the terminal), or when the hook
/// process goes away.
@MainActor
final class AIUsagePermissionBroker {
    private struct Pending {
        let request: AIUsagePermissionRequest
        let toolUseID: String?
        /// Held open for yes/no permissions; questions and plans are answered in Claude
        /// Code, so their hook returns at once and they are tracked until resolved.
        let responder: AIUsageHookServer.Responder?
    }

    private var pending: [Pending] = []
    var onChange: (() -> Void)?

    var requests: [AIUsagePermissionRequest] { pending.map(\.request) }

    func add(_ event: AIUsageHookEvent, responder: AIUsageHookServer.Responder) {
        let request = AIUsagePermissionRequest(
            id: event.toolUseID ?? UUID().uuidString,
            sessionID: event.sessionID,
            project: event.project,
            toolName: event.toolName ?? "Tool",
            summary: event.toolSummary ?? "",
            createdAt: Date(),
            kind: event.requestKind
        )
        if let sessionID = event.sessionID {
            finish(where: { $0.request.sessionID == sessionID }, decision: nil)
        }
        if request.needsDecision {
            responder.onClientGone = { [weak self] in
                Task { @MainActor in self?.finish(where: { $0.request.id == request.id }, decision: nil) }
            }
            pending.append(Pending(request: request, toolUseID: event.toolUseID, responder: responder))
        } else {
            // No decision from the notch: Claude Code shows its own form right away.
            responder.respond()
            pending.append(Pending(request: request, toolUseID: event.toolUseID, responder: nil))
        }
        onChange?()
    }

    func answer(id: String, decision: AIUsagePermissionDecision) {
        finish(where: { $0.request.id == id && $0.request.needsDecision }, decision: decision)
    }

    /// The session moved on (a new prompt, the turn ended): nothing it asked is pending.
    func resolvedElsewhere(sessionID: String?, toolUseID: String?) {
        finish(where: { entry in
            if let toolUseID, entry.toolUseID == toolUseID { return true }
            if let sessionID, entry.request.sessionID == sessionID { return true }
            return false
        }, decision: nil)
    }

    /// A tool finished (`PostToolUse`): its request was answered. Questions arrive without a
    /// `tool_use_id`, so those match by session and tool name instead; requests that carry
    /// an id only match that id, so parallel tools in one session stay separate.
    func toolFinished(sessionID: String?, toolUseID: String?, toolName: String?) {
        finish(where: { entry in
            if let toolUseID, entry.toolUseID == toolUseID { return true }
            guard entry.toolUseID == nil, let sessionID, entry.request.sessionID == sessionID else { return false }
            return entry.request.toolName == toolName
        }, decision: nil)
    }

    func cancelAll() {
        finish(where: { _ in true }, decision: nil)
    }

    private func finish(where predicate: (Pending) -> Bool, decision: AIUsagePermissionDecision?) {
        let matched = pending.filter(predicate)
        guard !matched.isEmpty else { return }
        pending.removeAll(where: predicate)
        // An empty 200 means "no decision": Claude Code keeps its own dialog.
        matched.forEach { $0.responder?.respond(body: decision?.hookOutput ?? Data()) }
        onChange?()
    }
}
