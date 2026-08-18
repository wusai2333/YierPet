import Foundation
import Network

/// Minimal loopback HTTP server receiving agent hook events.
/// One request per connection: parse, deliver, respond, close.
final class AgentServer {
    var onEvent: ((AgentEvent) -> Void)?

    /// Queue for listening and event delivery. Main by default so the app
    /// receives events on the main thread; tests swap in a private queue
    /// because `swift test` never drains the main queue.
    var queue: DispatchQueue = .main

    private var listener: NWListener?
    private(set) var port: UInt16?

    static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".yierpet")
    static let endpointURL = dir.appendingPathComponent("endpoint")

    var endpointString: String? {
        port.map { "http://127.0.0.1:\($0)/event" }
    }

    func start() {
        let params = NWParameters.tcp
        // 仅本机回环可达
        params.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener
        let queue = self.queue
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.port = listener.port?.rawValue
                self.writeEndpointFile()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            self?.receive(connection: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        try? FileManager.default.removeItem(at: Self.endpointURL)
    }

    private func writeEndpointFile() {
        guard let endpoint = endpointString else { return }
        try? FileManager.default.createDirectory(
            at: Self.dir, withIntermediateDirectories: true)
        try? endpoint.data(using: .utf8)?.write(to: Self.endpointURL)
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 16384
        ) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let event = Self.parse(accumulated) {
                self.onEvent?(event)
                self.respond(connection: connection, status: "200 OK")
                return
            }
            if error != nil || isComplete || accumulated.count > 65536 {
                self.respond(connection: connection, status: "400 Bad Request")
                return
            }
            self.receive(connection: connection, buffer: accumulated)
        }
    }

    /// Parses one complete HTTP request (headers + body) into an event.
    private static func parse(_ data: Data) -> AgentEvent? {
        guard let text = String(data: data, encoding: .utf8),
              let split = text.range(of: "\r\n\r\n")
        else { return nil }
        let head = String(text[..<split.lowerBound])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = split.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard text[bodyStart...].utf8.count >= contentLength else {
            return nil  // body 未收全，继续等
        }
        guard let tool = AgentTool(rawValue: headers["x-yierpet-tool"] ?? ""),
              let hook = headers["x-yierpet-hook"]
        else { return nil }
        return AgentEvent(
            tool: tool, hook: hook, cwd: headers["x-yierpet-cwd"] ?? "")
    }

    private func respond(connection: NWConnection, status: String) {
        let response =
            "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
