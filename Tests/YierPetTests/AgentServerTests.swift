import Foundation
import Testing
@testable import YierPet

/// swift test 里造的每个 server 都必须把 endpoint 落到临时目录：
/// 默认的 ~/.yierpet/endpoint 是真实 app 在用的文件，测试 defer { stop() }
/// 会把它删掉，于是所有 agent 钩子静默失效（hook.sh 读不到端点直接 exit 0）。
private func isolatedServer(label: String) -> (
    server: AgentServer, dir: URL, file: URL
) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-server-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let server = AgentServer()
    server.queue = DispatchQueue(label: label)
    server.endpointOverride = dir.appendingPathComponent("endpoint")
    return (server, dir, dir.appendingPathComponent("endpoint"))
}

// `swift test` never drains the main queue (nothing runs the main run
// loop there), so the server listens on a private queue and the waits
// below poll in 50 ms slices until the deadline.
@Test func testReceivesPostedEvent() {
    let (server, testDir, _) = isolatedServer(label: "AgentServerTests.event")
    defer { try? FileManager.default.removeItem(at: testDir) }
    var received: AgentEvent?
    server.onEvent = { received = $0 }
    server.start()
    defer { server.stop() }

    // 等监听就绪（端口由系统分配）
    let readyDeadline = Date().addingTimeInterval(5)
    while server.endpointString == nil && Date() < readyDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let endpoint = server.endpointString,
          let url = URL(string: endpoint)
    else {
        Issue.record("server never became ready")
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("qwen", forHTTPHeaderField: "X-YierPet-Tool")
    request.setValue("PermissionRequest", forHTTPHeaderField: "X-YierPet-Hook")
    request.setValue("/w/proj", forHTTPHeaderField: "X-YierPet-Cwd")
    request.httpBody = Data("{}".utf8)
    URLSession.shared.dataTask(with: request).resume()

    let deadline = Date().addingTimeInterval(5)
    while received == nil && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(received?.tool == .qwen)
    #expect(received?.hook == "PermissionRequest")
    #expect(received?.cwd == "/w/proj")
}

@Test func testGarbageRequestDoesNotCrash() {
    let (server, testDir, _) = isolatedServer(label: "AgentServerTests.garbage")
    defer { try? FileManager.default.removeItem(at: testDir) }
    server.start()
    defer { server.stop() }
    let readyDeadline = Date().addingTimeInterval(5)
    while server.endpointString == nil && Date() < readyDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let endpoint = server.endpointString,
          let url = URL(string: endpoint)
    else {
        Issue.record("server never became ready")
        return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    request.httpBody = Data("not http at all".utf8)
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in sem.signal() }
        .resume()
    _ = sem.wait(timeout: .now() + 5)
    // 活着走到这里即通过（服务未崩溃、连接被正常关闭）
}

@Test func deliversBodyAsPayload() throws {
    let (server, testDir, _) = isolatedServer(label: "agent-server-test-1")
    defer { try? FileManager.default.removeItem(at: testDir) }
    var received: AgentEvent?
    server.onEvent = { received = $0 }
    server.start()
    defer { server.stop() }
    let readyDeadline = Date().addingTimeInterval(5)
    while server.endpointString == nil && Date() < readyDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let endpoint = server.endpointString,
          let url = URL(string: endpoint)
    else {
        Issue.record("server never became ready")
        return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    request.setValue("qwen", forHTTPHeaderField: "X-YierPet-Tool")
    request.setValue("Notification", forHTTPHeaderField: "X-YierPet-Hook")
    request.setValue("/w/proj", forHTTPHeaderField: "X-YierPet-Cwd")
    request.httpBody = Data(#"{"message":"hi"}"#.utf8)
    URLSession.shared.dataTask(with: request).resume()
    let deadline = Date().addingTimeInterval(5)
    while received == nil && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(received?.payload == Data(#"{"message":"hi"}"#.utf8))
}

@Test func negativeContentLengthRejectedWithoutCrash() {
    let (server, testDir, _) = isolatedServer(label: "AgentServerTests.negative-cl")
    defer { try? FileManager.default.removeItem(at: testDir) }
    var received: AgentEvent?
    server.onEvent = { received = $0 }
    server.start()
    defer { server.stop() }
    let readyDeadline = Date().addingTimeInterval(5)
    while server.endpointString == nil && Date() < readyDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let port = server.port else {
        Issue.record("server never became ready")
        return
    }

    // URLSession 会按 body 改写 Content-Length，负数头必须手搓原始 TCP
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        Issue.record("socket() failed")
        return
    }
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
               socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        Issue.record("connect() failed")
        return
    }
    let raw = "POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        + "X-YierPet-Tool: qwen\r\nX-YierPet-Hook: Stop\r\n"
        + "Content-Length: -1\r\n\r\n"
    _ = raw.withCString { write(fd, $0, strlen($0)) }
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        response.append(contentsOf: buf[..<n])
    }
    // 服务未崩溃、以 400 拒绝，且不交付事件
    #expect(String(data: response, encoding: .utf8)?
        .contains("400") == true)
    #expect(received == nil)
}

@Test func oversizedBodyDeliversEventWithoutPayload() throws {
    let (server, testDir, _) = isolatedServer(label: "agent-server-test-2")
    defer { try? FileManager.default.removeItem(at: testDir) }
    var received: AgentEvent?
    server.onEvent = { received = $0 }
    server.start()
    defer { server.stop() }
    let readyDeadline = Date().addingTimeInterval(5)
    while server.endpointString == nil && Date() < readyDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let endpoint = server.endpointString,
          let url = URL(string: endpoint)
    else {
        Issue.record("server never became ready")
        return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("qwen", forHTTPHeaderField: "X-YierPet-Tool")
    request.setValue("Stop", forHTTPHeaderField: "X-YierPet-Hook")
    request.setValue("/w/proj", forHTTPHeaderField: "X-YierPet-Cwd")
    request.httpBody = Data(repeating: 65, count: 3 * 1024 * 1024)
    URLSession.shared.dataTask(with: request).resume()
    let deadline = Date().addingTimeInterval(10)
    while received == nil && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(received?.hook == "Stop")
    #expect(received?.payload == nil)
}
