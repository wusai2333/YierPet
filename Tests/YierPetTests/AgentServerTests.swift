import Foundation
import Testing
@testable import YierPet

// `swift test` never drains the main queue (nothing runs the main run
// loop there), so the server listens on a private queue and the waits
// below poll in 50 ms slices until the deadline.
@Test func testReceivesPostedEvent() {
    let server = AgentServer()
    server.queue = DispatchQueue(label: "AgentServerTests.event")
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
    let server = AgentServer()
    server.queue = DispatchQueue(label: "AgentServerTests.garbage")
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
    let server = AgentServer()
    server.queue = DispatchQueue(label: "agent-server-test-1")
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

@Test func oversizedBodyDeliversEventWithoutPayload() throws {
    let server = AgentServer()
    server.queue = DispatchQueue(label: "agent-server-test-2")
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
