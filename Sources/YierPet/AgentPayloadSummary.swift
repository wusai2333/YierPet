import Foundation

/// Extracts a short human-readable summary from agent hook payloads.
/// Pure and best-effort: returns nil when nothing sensible is found, so
/// reminders always fire with or without a summary.
enum AgentPayloadSummary {
    static let maxChars = 60
    private static let transcriptTailBytes = 65536
    private static let toolInputKeys = [
        "command", "script", "file_path", "path", "query",
    ]

    /// Main entry: summarizes an event payload for the given tool/hook.
    static func summary(
        tool: AgentTool, hook: String, payload: Data?, cwd: String
    ) -> String? {
        guard let payload, !payload.isEmpty else { return nil }
        let raw: String?
        switch (tool, hook) {
        case (.qwen, "Notification"), (.qodercli, "Notification"),
             (.dsh, "Notification"):
            raw = stringValue(in: payload, key: "message")
        case (.qwen, "PermissionRequest"), (.qodercli, "PermissionRequest"),
             (.dsh, "PermissionRequest"):
            raw = permissionSummary(payload)
        case (.qwen, "Stop"), (.qodercli, "Stop"):
            raw = transcriptSummary(payload)
        case (.qwen, "PostToolUseFailure"), (.qodercli, "PostToolUseFailure"),
             (.dsh, "PostToolUseFailure"):
            raw = firstString(payload, keys: ["error", "message", "tool_response"])
        case (.dsh, "Stop"), (.omp, "Stop"), (.omo, "Stop"), (.opencode, "Stop"):
            raw = stringValue(in: payload, key: "text")
        case (.opencode, "PermissionRequest"):
            raw = stringValue(in: payload, key: "permission")
        case (.opencode, "PostToolUseFailure"):
            raw = stringValue(in: payload, key: "error")
        default:
            return nil
        }
        return clean(raw)
    }

    /// Compresses whitespace/newlines, trims, truncates to maxChars.
    static func clean(_ string: String?) -> String? {
        guard let string else { return nil }
        let flattened = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > maxChars else { return flattened }
        return String(flattened.prefix(maxChars)) + "…"
    }

    /// Reads the tail of a JSONL transcript and returns the last
    /// assistant text. Best-effort: any parse/read problem returns nil.
    static func lastAssistantText(
        inTranscript path: String, tailBytes: Int = transcriptTailBytes
    ) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: offset)
        guard var data = try? handle.readToEnd() else { return nil }
        // A nonzero offset may land mid-line (or mid-UTF-8 sequence);
        // drop the first partial line so decoding stays valid.
        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        guard let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(
                      with: lineData)) as? [String: Any]
            else { continue }
            if let found = assistantText(in: object) { return found }
        }
        return nil
    }

    // MARK: - Internals

    private static func transcriptSummary(_ payload: Data) -> String? {
        guard let path = stringValue(in: payload, key: "transcript_path")
        else { return nil }
        return lastAssistantText(inTranscript: path)
    }

    private static func permissionSummary(_ payload: Data) -> String? {
        guard let object = jsonObject(payload) else { return nil }
        guard let toolName = object["tool_name"] as? String,
              !toolName.isEmpty
        else { return object["message"] as? String }
        let input = object["tool_input"] as? [String: Any]
        for key in toolInputKeys {
            if let value = input?[key] as? String, !value.isEmpty {
                return "\(toolName)：\(value)"
            }
        }
        return toolName
    }

    /// Extracts assistant text from one transcript record (CC/qwen shape:
    /// {"message":{"role":"assistant","content":[...]}}) or a bare
    /// pi-style message object ({"role":"assistant","content":...}).
    private static func assistantText(in object: [String: Any]) -> String? {
        if let message = object["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            return contentText(message["content"])
        }
        if (object["role"] as? String) == "assistant" {
            return contentText(object["content"])
        }
        return nil
    }

    private static func contentText(_ content: Any?) -> String? {
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringValue(in payload: Data, key: String) -> String? {
        jsonObject(payload)?[key] as? String
    }

    private static func firstString(_ payload: Data, keys: [String]) -> String? {
        guard let object = jsonObject(payload) else { return nil }
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
