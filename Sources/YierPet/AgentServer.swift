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
    /// 测试用：换掉落盘位置，别真去动 ~/.yierpet/endpoint。
    var endpointOverride: URL?
    private var endpointFile: URL { endpointOverride ?? Self.endpointURL }

    var endpointString: String? {
        port.map { "http://127.0.0.1:\($0)/event" }
    }

    func start() {
        // 幂等：先收掉旧 listener，重复调用（如菜单重装钩子）不泄漏。
        // 重绑期间**不删** endpoint 文件：删了要等新监听器 .ready 才写回，
        // 这个窗口里 hook.sh 读不到端点会静默 exit 0，事件全丢（实测发生过）。
        // 新端口就绪后原子覆盖旧内容，读方只会看到"旧的或新的"。
        shutdown(removeEndpoint: false)
        bind()
    }

    private func bind() {
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
        shutdown(removeEndpoint: true)
    }

    private func shutdown(removeEndpoint: Bool) {
        listener?.cancel()
        listener = nil
        port = nil
        if removeEndpoint {
            try? FileManager.default.removeItem(at: endpointFile)
        }
    }

    private func writeEndpointFile() {
        guard let endpoint = endpointString else { return }
        try? FileManager.default.createDirectory(
            at: endpointFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // .atomic：写临时文件再 rename，读方永远看到"旧的或新的"，不会读到半个 URL
        try? endpoint.data(using: .utf8)?.write(
            to: endpointFile, options: .atomic)
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 16384
        ) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            switch Self.parse(accumulated) {
            case .event(let event):
                self.onEvent?(event)
                self.respond(connection: connection, status: "200 OK")
            case .invalid:
                self.respond(connection: connection, status: "400 Bad Request")
            case .incomplete:
                if error != nil || isComplete
                    || accumulated.count > Self.maxBodyBytes + 4096 {
                    self.respond(
                        connection: connection, status: "400 Bad Request")
                    return
                }
                self.receive(connection: connection, buffer: accumulated)
            }
        }
    }

    private static let maxBodyBytes = 2 * 1024 * 1024

    private enum ParseResult {
        case incomplete
        case invalid
        case event(AgentEvent)
    }

    /// Parses one complete HTTP request (headers + body) into an event.
    private static func parse(_ data: Data) -> ParseResult {
        guard let text = String(data: data, encoding: .utf8),
              let split = text.range(of: "\r\n\r\n")
        else { return .incomplete }
        let head = String(text[..<split.lowerBound])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let tool = AgentTool(rawValue: headers["x-yierpet-tool"] ?? ""),
              let hook = headers["x-yierpet-hook"]
        else { return .invalid }
        let cwd = headers["x-yierpet-cwd"] ?? ""
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        // 负数 Content-Length 非法：拒绝，防 prefix 负数越界崩溃
        guard contentLength >= 0 else { return .invalid }
        // 超限：丢摘要不丢提醒，不等 body 直接交付（payload 为 nil）
        guard contentLength <= maxBodyBytes else {
            return .event(AgentEvent(tool: tool, hook: hook, cwd: cwd))
        }
        let bodyStart = split.upperBound
        let bodyText = text[bodyStart...]
        guard bodyText.utf8.count >= contentLength else {
            return .incomplete  // body 未收全，继续等
        }
        return .event(
            AgentEvent(
                tool: tool, hook: hook, cwd: cwd,
                payload: Data(bodyText.utf8.prefix(contentLength))))
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
