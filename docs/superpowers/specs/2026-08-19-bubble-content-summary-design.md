# YierPet Agent 哨兵：气泡内容摘要

日期：2026-08-19
状态：已与用户对齐，待实现

## 1. 背景与目标

Agent 哨兵现有提醒只有模板文案（"qwen 在 YierPet 等你确认呢"），用户看不出具体在确认什么、干完了什么。
目标：三种提醒（等确认/完成/报错）的气泡里附带**会话内容摘要**，让用户不切窗口就能判断要不要过去处理。

已确认的需求决策：
- 三种提醒都带内容摘要
- "完成"摘要取 **agent 最后一条回复**（qwen/qodercli 读 transcript 文件；omp/omo/opencode 事件里直接带文本）
- 摘要长度上限 **60 字**，超出截断加 …

## 2. 现状与改动面

现有链路：钩子 stdin JSON → hook.sh/插件 POST → `AgentServer.parse` **丢弃 body**，只取 3 个 header → `AgentEvent { tool, hook, cwd }` → 状态机 → 气泡。

改动：body 不再丢弃，沿链路携带并提取摘要：

```
payload（Data）→ AgentEvent.payload → AgentPayloadSummary 提取 → AgentAlert.detail → 气泡第二行
```

## 3. 摘要来源（按工具）

| 提醒 | qwen / qodercli | omp / omo | opencode |
|---|---|---|---|
| 等确认 | Notification → payload `message` 字段；PermissionRequest → `tool_name` + `tool_input` 首个有意义字段（按 command/script/file_path/path/query 顺序取第一个存在的），摘要格式 `<tool_name>：<字段值>`，如 `shell：ls -la` | 无（未订阅权限类事件，且用户跑 yolo 模式，等确认本就不触发） | `permission.ask` hook 的 Permission 对象（类型+对象描述） |
| 完成 | Stop payload 带 `transcript_path`：读该 JSONL 文件**尾部 64KB**，从后往前找最后一条助手文本（content 数组的 text 块拼接） | 扩展维护 `lastAssistantText`（message_end 时更新），agent_settled/agent_end POST 时附带 | 插件从 message 事件跟踪最后助手文本，session.idle POST 时附带 |
| 报错 | PostToolUseFailure payload 尽力取 error/message/tool_response 等字段 | 现状 pi 事件无错误文本，保持无摘要 | session.error 事件 properties 里的错误信息 |

所有提取**尽力而为**：字段缺失、格式不符、文件读不到 → 返回 nil，降级为现有无摘要文案，绝不影响提醒本身。

## 4. 展示格式

现有文案模板不变，有摘要时另起一行加『』：

```
qwen 在 YierPet 等你确认呢，快去瞅瞅！
『要执行 shell：rm -rf /tmp/cache』
```

- 截断：摘要超过 60 个字符（Character 位素，emoji 安全）→ 前 60 字 + "…"
- 气泡组件（SpeechBubble）**零改动**：已支持 220pt 宽自动换行、高度自适应
- 轻提醒（needsConfirm 每 120s 重提醒）复用会话最近一次的摘要：Session 增加 `lastDetail` 字段，事件带摘要时更新

## 5. AgentServer 行为调整

- body 随事件交付：`AgentEvent` 增加 `payload: Data?`
- 上限从 64KB 提到 **2MB**；body 超限时**事件照常送达、payload 置 nil**（现状是整个事件丢弃——会漏提醒；新行为丢摘要不丢提醒）
- 解析仍只需 header + body 收全，不解析 JSON 内容（解析在提取器里做）

## 6. 插件/扩展源码更新

omp/omo 扩展与 opencode 插件的内嵌源码（`AgentHookInstaller` 里的 TS 常量）需要升级为携带内容：

- omp/omo：`message_end` 提取助手文本存入模块级变量；`agent_settled`/`agent_end` POST 带 `{text: lastAssistantText}`；`agent_start` 时清空
- opencode：`message.updated`/`message.part.updated` 事件跟踪最后助手文本；`permission.ask` POST 权限描述；`session.idle` POST 最后文本；`session.error` POST 错误信息
- 助手文本提取规则与 orca-agent-status.ts 的 extractAssistantText 同款：message.content 里 text 类型块拼接
- POST body 仍受 1s 超时与 catch 吞错约束，body 变大不改变"绝不阻塞 agent"承诺

**部署**：用户重新点一次"安装 Agent 钩子"（安装器幂等覆盖三个 TS 文件）。

## 7. YierPet 侧改动清单

1. `AgentServer.swift`：parse 保留 body、2MB 上限、超限交付 nil payload
2. `AgentSessionStore.swift`：`AgentEvent` 加 `payload: Data?`；`Session` 加 `lastDetail: String?`；`AgentAlert` 加 `detail: String?`；apply/dueNudges 传递
3. **新文件** `AgentPayloadSummary.swift`：纯函数提取器 `summary(tool:hook:payload:) -> String?` + transcript 尾部读取器（可注入路径，便于测试）+ 60 字截断
4. `AgentCenter.swift`：handle() 里调提取器；message(for:) 拼接『』行
5. `AgentHookInstaller.swift`：三段 TS 源码常量更新
6. README：Agent 哨兵小节补一句"气泡附带会话内容摘要（仅本机处理）"

## 8. 错误处理

| 场景 | 行为 |
|---|---|
| payload 非法 JSON / 缺字段 | 无摘要，提醒照常 |
| transcript 文件不存在/读失败/格式不符 | 无摘要，提醒照常 |
| payload > 2MB | 事件送达、无摘要 |
| 摘要含换行/控制字符 | 压成空格后再截断 |

## 9. 测试

- 提取器单测（Swift Testing，fixture payload）：qwen Notification message、PermissionRequest tool_input 取 command/file_path、PostToolUseFailure error 字段、非法 JSON → nil
- transcript 读取器单测：临时 JSONL 文件（多轮对话取最后助手文本、空文件、无助手消息、超大文件只读尾部）
- 截断单测：60 字边界、emoji、换行压缩
- 手工 E2E：qwen 实跑触发权限弹窗看气泡内容；omo/opencode 各跑一轮看完成摘要

## 10. 非目标

- 不做内容总结/LLM 摘要（只截取原文片段）
- 不做点击气泡看全文
- 不持久化摘要内容
