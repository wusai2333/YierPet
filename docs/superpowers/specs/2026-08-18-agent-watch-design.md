# YierPet Agent 哨兵：本地 Agent 工作状态监听与提醒

日期：2026-08-18
状态：已与用户对齐，待实现

## 1. 背景与目标

用户日常同时运行多个终端 AI agent（qwen、qodercli、opencode、omp/oh-my-pi、dsh）。
agent 在等待人工确认、报错或完成任务时，用户常常察觉不到。
目标：YierPet 桌宠实时镜像这些 agent 的工作状态，并在以下时刻主动提醒：

1. **需要人工确认/输入**（核心）：气泡 + 动作 + 提示音，未解决每 120s 轻提醒一次
2. **出错**：气泡 + 动作 + 低音，同会话 60s 节流
3. **任务完成（空闲）**：气泡 + 动作，无提示音
4. **工作中展示**：有任一 working 会话时，宠物待机偏向播放 `work` 标签表情（不打扰）

接入方式：**钩子推送**（用户已确认）。各工具的 hook/插件机制把事件实时推给 YierPet。

### 非目标

- 点击气泡跳转到对应终端窗口（实现复杂，用户未选）
- 主动探测"卡死/被杀"的会话（仅被动接收事件 + 静默超时清理，避免误报）
- 设置界面窗口（沿用项目右键菜单惯例）
- Windows / Linux 支持

## 2. 调研结论（已在本机验证）

| 工具 | 二进制/配置 | 接入机制 |
|---|---|---|
| qwen (qwencode) | `~/.qwen/settings.json` | hooks：源码确认支持 Notification、PermissionRequest、Stop、SessionStart/End、UserPromptSubmit、PreToolUse、PostToolUse、PostToolUseFailure、SubagentStart/Stop、PreCompact |
| qodercli | `~/.qoder/settings.json` | Claude Code 风格 hooks（已有 Notification 等配置；现存 yunke 钩子为数组成员，追加不覆盖） |
| opencode | `~/.config/opencode/` | 插件（plugins/ 目录，用户已有 ai-coding-trace-opencode.js 先例）；具体事件名以实现时安装的 opencode 版本 API 为准 |
| omp (oh-my-pi) | `~/.omp/agent/extensions/` | 扩展机制；用户已有 `orca-agent-status.ts`（事件 POST 到端点文件），同款模式可直接参考。注意用户 omp 为 yolo 模式，"等确认"基本不会触发 |
| dsh (deepseek-harness) | `~/.dsh/`，源码在 `~/Work/tools/deepseek-harness` | 基于 pi 框架；orca 扩展注释明确 "Pi and OMP expose the same extension API"，实现时确认。**dsh 自带桌宠（鲸鱼娘），接入后将其 `pet.visible` 设为 false，由 YierPet 取代（用户已确认）** |

YierPet 现状（约 2000 行，纯 AppKit 零依赖，全主线程 Timer 驱动）：

- 提醒链路模板：`ReminderCenter`（30s tick + 优先级 + 90s globalGap）→ delegate → `PetController.say()` + 动画
- 动画两套体系：经典图集 `PetState`（9 状态）与表情包 tag 驱动（`playStickerTags`）；外部事件→动作的映射集中在 `PetController` 末尾 delegate extension 的两个 exhaustive switch
- 气泡 `SpeechBubble` 为子窗口，自动跟随宠物
- 配置仅 UserDefaults + 右键菜单；构建走 `swiftc -O Sources/YierPet/*.swift` glob，新增源文件零配置成本
- README 宣称"零依赖、零权限、不起子进程"，新增本机回环监听需同步更新表述

## 3. 总体架构

```
qwen hooks ────┐
qodercli hooks ─┤
opencode 插件 ──┼──► ~/.yierpet/hook.sh（curl -m 1，静默失败）
omp 扩展 ──────┤              │
dsh hooks ─────┘              ▼
                YierPet AgentServer（NWListener，仅 127.0.0.1）
                              ▼
                AgentCenter（会话状态机 + 聚合 + 去重/升级）
                              ▼ AgentCenterDelegate
                PetController（气泡 + 动作/表情 + 提示音）
```

- YierPet 启动时用 Network.framework `NWListener` 绑定 `127.0.0.1` 的**随机可用端口**（端口 0），
  把实际地址写入 `~/.yierpet/endpoint`（内容如 `http://127.0.0.1:54321/event`）。
  hook.sh 每次执行时读该文件，因此 YierPet 重启换端口也无需重装钩子。
- opencode 插件与 omp/dsh 扩展是 JS/TS，直接用内置 http/fetch POST，不走 hook.sh，
  端点同样读 `~/.yierpet/endpoint`（照抄 `orca-agent-status.ts` 的端点文件 + 缓存模式）。
- YierPet 未运行时：endpoint 文件可能过期，curl 1s 超时静默失败，**绝不阻塞 agent**。

## 4. 事件协议

hook.sh 不解析 JSON：钩子 stdin 的原始 JSON 直接作为 POST body，元信息走 HTTP header：

```
POST /event HTTP/1.1
Content-Type: application/json
X-YierPet-Tool: qwen            # qwen|qodercli|opencode|omp|dsh
X-YierPet-Hook: PermissionRequest
X-YierPet-Cwd: /Users/wusai/Work/tools/YierPet

{ ...工具原始钩子 JSON，YierPet 只按需取 session_id 等可选字段... }
```

hook.sh 参考实现（最终版以实现为准）：

```sh
#!/bin/sh
# usage: hook.sh <tool> <hook-event>
endpoint=$(cat "$HOME/.yierpet/endpoint" 2>/dev/null)
[ -n "$endpoint" ] || exit 0
curl -m 1 -s -o /dev/null -X POST "$endpoint" \
  -H "Content-Type: application/json" \
  -H "X-YierPet-Tool: $1" \
  -H "X-YierPet-Hook: $2" \
  -H "X-YierPet-Cwd: $PWD" \
  --data-binary @- 2>/dev/null
exit 0
```

YierPet 内部归一化为：

```swift
struct AgentEvent {
    let tool: String        // qwen / qodercli / opencode / omp / dsh
    let hook: String        // 原始钩子事件名
    let cwd: String         // 项目路径（会话聚合键之一）
    let session: String?    // payload 里的 session_id（如有，仅展示用）
}
```

## 5. 状态模型与提醒策略

会话键：`tool + cwd`（用户已确认：同项目多个同类 agent 合并为一个状态）。

| 钩子事件 | 会话状态迁移 | 提醒 |
|---|---|---|
| UserPromptSubmit / PreToolUse / PostToolUse / SubagentStart / SubagentStop 等 | → working（心跳；SubagentStop 只是子 agent 结束，主 agent 仍在工作，不算完成） | 无 |
| PermissionRequest / Notification | → **needsConfirm** | 气泡+动作+提示音；未解决每 120s 轻提醒 |
| Stop | → done | 气泡+动作，无提示音 |
| PostToolUseFailure | 保持 working，错误计数 | 气泡+动作+低音，同会话 60s 节流 |
| SessionEnd | 移除会话 | 无 |
| working 状态静默 ≥ 10 分钟 | 移除会话（视为结束/中断） | 无（避免误报） |

说明：Notification 钩子在权限请求和空闲等待时都会触发，两者语义都是"agent 在等人"，统一按 needsConfirm 处理，不按 payload 细分。

- "解决"判定：needsConfirm 的会话收到任何 working/done 事件即视为已处理，停止轻提醒。
- 多会话聚合优先级：**needsConfirm > error > done**；同一时刻只冒一条气泡（后来的覆盖先来的，与现有 SpeechBubble 行为一致）。
- 提醒文案带 `{tool}`、`{proj}`（cwd 末段）占位符，走 `ReminderCenter.messages` 语料池模式，例如：
  - needsConfirm："`{tool}` 在 {proj} 等你确认呢，快去瞅瞅！"
  - done："「{proj}」的活儿干完啦，等你下一句～"
  - error："{tool} 在 {proj} 碰壁了……要不要去看看？"
- agent 提醒**不受** ReminderCenter 90s globalGap 约束（人工确认是紧急事件），但受自身去重约束。

## 6. YierPet 侧改动

### 新增文件（构建 glob 自动纳入）

1. **`Sources/YierPet/AgentCenter.swift`**
   - `AgentServer`：NWListener 最小 HTTP 服务（仅解析 POST /event 的 header + body，回 200；其余回 404）。回调 hop 到主线程。启动后写 `~/.yierpet/endpoint`，退出时删除。
   - `AgentCenter`：会话表 `[String: SessionState]`、状态迁移、去重时间戳、needsConfirm 升级提醒与静默清理（自持一个 30s tick 主线程 Timer，与 ReminderCenter 的 tick 相互独立）。
   - `AgentCenterDelegate`：`agentCenter(_:fire:message:tool:)` 等回调。
2. **`Sources/YierPet/AgentHookInstaller.swift`**
   - 安装/卸载 5 个工具的钩子（见 §7），全部幂等、基于 `yierpet` 标记串识别自有条目。

### 修改现有文件

1. **`ReminderCenter.swift`**：`ReminderKind` 新增 3 个 case（agentNeedsConfirm / agentDone / agentError）+ `isAgent` 分组布尔 + `agentCases` 静态属性 + 对应文案语料。
2. **`PetController.swift`**：
   - 持有 `agentCenter`（与 `reminderCenter` 并列），启动/停止随生命周期；
   - 实现 `AgentCenterDelegate`：映射到气泡 + 动画 + 提示音：
     - needsConfirm → 经典 `.waiting` / 贴纸 `["hot", "tired"]`，NSSound 清脆音效
     - done → 经典 `.waving` / 贴纸 `["happy"]`，无声音
     - error → 经典 `.failed` / 贴纸 `["sad", "tired"]`，NSSound 低沉音效
   - `contextTags`：存在任一 working 会话时，normal 心情的待机标签前置 `"work"`；
   - `buildMenu()`：新增"**Agent 哨兵**"子菜单：总开关、5 个工具开关、提示音开关、"安装钩子…"、"卸载钩子"、当前会话状态列表（只读展示项）。
3. **`README.md`**：更新"零依赖"表述，说明 Agent 哨兵功能引入仅本机回环的 HTTP 监听（无网络权限请求、无子进程）。

### 配置项（UserDefaults）

- `agent.enabled`（总开关，默认开）
- `agent.tool.<tool>.enabled` × 5（默认开）
- `agent.sound.enabled`（默认开）

## 7. 安装/卸载流程

**安装**（菜单"安装钩子"，一键）：

1. 建 `~/.yierpet/`，写入 hook.sh 并 chmod +x；
2. 逐工具合并配置（每个文件写入前先备份为 `<file>.yierpet-bak`，已有备份则不覆盖）：
   - qwen / qodercli：向 `settings.json` 的 `hooks` 追加条目，命令为 `~/.yierpet/hook.sh <tool> <Event>`，覆盖事件集：PermissionRequest、Notification、Stop、UserPromptSubmit、PostToolUseFailure、SessionEnd（qwen 按源码确认的事件名；qodercli 按 Claude Code 兼容事件名，实现时以其 settings 现有结构为准）。JSON 解析失败则跳过该工具并气泡提示，绝不写坏配置；
   - opencode：写入 `~/.config/opencode/plugins/yierpet.ts`（订阅权限请求/会话空闲/消息事件，映射为 needsConfirm/done/working）；
   - omp：写入 `~/.omp/agent/extensions/yierpet-status.ts`（参考 orca-agent-status.ts 的端点文件读取 + 防抖 POST 模式）；
   - dsh：扩展接入（实现时确认 pi 框架扩展点，预期与 omp 同款 API）；并将 `~/.dsh/settings.yaml` 的 `pet.visible` 置为 false。
3. 气泡反馈安装结果。

**卸载**（菜单"卸载钩子"）：按 `yierpet` 标记从各配置中精确移除自有条目（数组中删自有元素，保留其他钩子如 yunke），删除插件/扩展文件、hook.sh 与 endpoint 文件；备份文件保留不动；dsh 的 `pet.visible` 不自动恢复（避免鲸鱼娘突然复活）。

## 8. 错误处理

| 场景 | 行为 |
|---|---|
| YierPet 未运行 / 端口变了 | 钩子 ≤1s 静默失败，agent 无感；YierPet 重启后重写 endpoint 即恢复 |
| 端口被占 | 绑端口 0 由系统分配，endpoint 文件写实际端口 |
| 工具配置文件解析失败 | 跳过该工具，气泡提示"X 安装失败"，不写任何内容 |
| 钩子风暴（高频 PostToolUse） | working 心跳只更新状态不提醒；HTTP 处理 O(1)，无队列积压（body 直接丢弃，只留解析出的字段） |
| 未知 tool/hook 名 | 忽略（回 200），不报错不崩溃 |

## 9. 测试

项目无 XCTest 先例，沿用现有惯例：

1. **隐藏测试菜单**（Option+右键）：新增"模拟 agent 等确认 / 完成 / 报错"条目，直调 AgentCenter 注入假事件，验证气泡、动画、提示音、去重与升级提醒全链路。
2. **手工 E2E 清单**（实现后逐项执行并记录结果）：
   - 跑一次 qwen，触发权限弹窗 → 宠物气泡+声音；在终端回应后 → 轻提醒停止
   - qwen 完成一轮回答 → done 气泡
   - 退出 YierPet 后运行带钩子的 agent → agent 不阻塞、无报错（钩子静默失败）
   - 重启 YierPet（端口变化）→ 钩子自动恢复
   - 安装/卸载钩子各跑一遍 → 各配置文件 diff 干净（只剩/只删 yierpet 条目），yunke 钩子不受影响
   - dsh 内置宠物确认已隐藏

## 10. 实现顺序建议（供 writing-plans 参考）

1. AgentCenter（server + 状态机）+ 测试菜单注入 → 先让 YierPet 侧闭环
2. hook.sh + qwen/qodercli 钩子安装器 → 第一个真实来源打通
3. opencode 插件、omp 扩展、dsh 扩展 + dsh 内置宠关闭
4. 菜单（开关/安装/卸载/状态展示）、提示音、README
