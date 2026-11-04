import Foundation
import Network
import Testing
@testable import YierPet

/// 端点文件的落盘策略：重绑不许制造"文件消失"的窗口，端口要尽量复用。
private func makePinnedServer(
    name: String
) -> (server: AgentServer, file: URL, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-endpoint-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let server = AgentServer()
    server.queue = DispatchQueue(label: name)
    server.endpointOverride = dir.appendingPathComponent("endpoint")
    return (server, dir.appendingPathComponent("endpoint"), dir)
}

private func waitReady(_ server: AgentServer, seconds: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while server.endpointString == nil && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return server.endpointString != nil
}

@Test func endpointSurvivesRebind() throws {
    let (server, file, dir) = makePinnedServer(name: "endpoint-rebind")
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    server.start()
    #expect(waitReady(server))
    let firstText = try? String(contentsOf: file, encoding: .utf8)
    guard let firstText, server.port != nil else {
        Issue.record("起服后端口或 endpoint 文件缺失"); return
    }
    #expect(firstText == server.endpointString)

    // 重绑期间反复采样文件：旧实现会先删再等新监听器就绪才写，
    // 这段时间里钩子读不到端点 —— 事件全部静默丢弃。
    var sawMissing = false
    var sawEmpty = false
    var running = true
    let rebindDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        server.start()
        while running { Thread.sleep(forTimeInterval: 0.02) }
        rebindDone.signal()
    }
    let until = Date().addingTimeInterval(1.5)
    while Date() < until {
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            if text.isEmpty { sawEmpty = true }
        } else {
            sawMissing = true
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
    running = false
    #expect(rebindDone.wait(timeout: .now() + 5) == .success)
    #expect(waitReady(server))

    #expect(!sawMissing, "重绑期间 endpoint 文件消失了")
    #expect(!sawEmpty, "重绑期间 endpoint 文件被写成了空内容")
    // 端口由系统重新分配，文件内容必须与之一致（钩子按文件里的地址投递）
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == server.endpointString)
}

@Test func stopRemovesEndpointFile() throws {
    let (server, file, dir) = makePinnedServer(name: "endpoint-stop")
    defer { try? FileManager.default.removeItem(at: dir) }
    server.start()
    #expect(waitReady(server))
    #expect(FileManager.default.fileExists(atPath: file.path))
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func staleEndpointFileDoesNotBlockStartup() throws {
    let (server, file, dir) = makePinnedServer(name: "endpoint-stale")
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }
    // 上一个实例留下的地址，端口早没了 —— 必须能正常起服并改写它
    try Data("http://127.0.0.1:1/event".utf8).write(to: file)
    server.start()
    #expect(waitReady(server))
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == server.endpointString)
    #expect(text != "http://127.0.0.1:1/event")
}

// 守门：跑 swift test 不许动真实的 ~/.yierpet/endpoint。
// 曾有 5 个服务端用例用默认落盘位置建 server，defer { stop() } 直接删掉真实文件，
// 六个 agent 的提醒一起静默消失（hook.sh 读不到端点就 exit 0）。
@Test func serverTestsDoNotTouchLiveEndpointFile() throws {
    let live = AgentServer.endpointURL
    func stat() -> (exists: Bool, data: Data?, inode: Int, mtime: Double) {
        guard FileManager.default.fileExists(atPath: live.path) else {
            return (false, nil, -1, 0)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: live.path)
        return (true, try? Data(contentsOf: live),
                attrs?[FileAttributeKey("inode")] as? Int ?? -1,
                (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
    let before = stat()

    let (server, dir, _) = makePinnedServer(name: "isolation")
    let file = try #require(server.endpointOverride)
    server.start()
    #expect(waitReady(server))
    // 隔离生效的直接证据：端点写在临时目录里
    let written = try String(contentsOf: file, encoding: .utf8)
    #expect(written == server.endpointString)
    let afterStart = stat()
    #expect(afterStart.exists == before.exists)
    #expect(afterStart.data == before.data)
    #expect(afterStart.inode == before.inode,
            "start() 重写了真实 endpoint（inode 变了）——落盘没走隔离")
    server.stop()
    try? FileManager.default.removeItem(at: dir)

    let after = stat()
    #expect(after.exists == before.exists, "真实 endpoint 文件的存在性被改动了")
    #expect(after.data == before.data, "真实 endpoint 文件内容被改动了")
    #expect(after.inode == before.inode,
            "真实 endpoint 被重写过（inode 漂移）——测试不许搬运用户的文件")
    #expect(after.mtime == before.mtime)
}
