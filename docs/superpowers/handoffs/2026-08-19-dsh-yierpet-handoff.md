# Handoff：把 dsh 接入 YierPet Agent 哨兵

> 读者：dsh 自己（或任何执行此任务的 agent）。本文自包含，无需其他上下文。
> 日期：2026-08-19

## 你的任务

dsh 是用户本地 6 个 agent CLI（qwen/qodercli/opencode/omp/omo/dsh）中唯一还没接入 YierPet 状态提醒的。YierPet 侧已完全就绪，你要做的是让 dsh 在关键生命周期时刻把事件推给 YierPet，并确认 TUI 鲸鱼娘不再显示。

## 背景：YierPet Agent 哨兵是什么

YierPet（`/Users/wusai/Work/tools/YierPet`）是 macOS 桌宠应用，监听本地 agent CLI 的状态，在「等确认 / 完成 / 报错」时通过气泡+动画+提示音提醒用户。其他 5 个工具已通过 hooks/插件/扩展接入；dsh 目前只完成了「取代内置宠物」，事件接入空缺。

**YierPet 侧无需任何改动**：工具枚举已有 `.dsh`，菜单已有「监听 dsh」开关，提醒管道通用。

## 推送协议（核心）

YierPet 运行时在本机 loopback 起 HTTP 监听，URL 写入 `~/.yierpet/endpoint`（内容形如 `http://127.0.0.1:PORT/eventhook`）。

一个事件 = 一个 POST：

| Header | 值 |
|---|---|
| `X-YierPet-Tool` | `dsh` |
| `X-YierPet-Hook` | 见下表 |
| `X-YierPet-Cwd` | 当前工作目录（用于会话聚合与项目名显示） |
| `Content-Type` | `application/json` |

body 为可选 JSON。钩子语义：

| Hook | 时机 | body |
|---|---|---|
| `UserPromptSubmit` | 新一轮用户输入开始 | 无 |
| `PostToolUse` | 工具执行完（心跳，显示"工作中"） | 无 |
| `Stop` | 回合结束/空闲 → 触发"完成"提醒 | `{"text": "最后一条回复文本"}` → 气泡摘要 |
| `PostToolUseFailure` | 工具出错（60s 节流） | `{"error": "错误信息"}` → 气泡摘要 |
| `PermissionRequest` / `Notification` | 需要人工确认 | `{"message": "要确认什么"}` → 气泡摘要 |
| `SessionEnd` | 会话彻底结束 | 无 |

摘要显示为气泡第二行『…』，60 字截断；body 缺失/非法时只发提醒不带摘要，不影响提醒本身。body 上限 2MB。

**铁律（不可妥协）：**
- 1 秒超时、所有错误静默吞掉、绝不阻塞 dsh 主流程
- endpoint 文件不存在（YierPet 没运行）→ 直接跳过，不重试不报错
- 推送是 fire-and-forget，不等响应内容

**参考实现**（读这两个文件就懂模式了）：
- `~/.omp/agent/extensions/yierpet-status.ts` — pi 风格扩展版（含完成摘要的 text 携带）
- `~/.yierpet/hook.sh` — shell 版转发器

**快速自测**（YierPet 运行时）：

```sh
printf '{"text":"dsh 接入测试"}' | ~/.yierpet/hook.sh dsh Stop
```

桌宠应弹出完成气泡，第二行『dsh 接入测试』。

## 已完成（不要重复做）

- `~/.dsh/settings.yaml` 的 `pet.visible: false` 已设置（dsh 内置桌面宠物已禁用，YierPet 取代；原文件备份在 `*.yierpet-bak`）
- YierPet 侧 `.dsh` 枚举、菜单开关、提醒管道全部就绪

## 待办

### A. 事件接入（主任务）

已知调研结论：dsh 没有 pi 风格的扩展目录，也没有 hooks 配置文件；插件体系是 Cordis（npm 包，按 profile 安装）。但**你比任何外部调研都更了解自己的内部**——请读自己的源码（`~/Work/tools/deepseek-harness`，已更新到 rc.7，commit 99f6f02fec）找最小接入点。候选方向：

1. **内部生命周期钩子/事件总线**：如果 dsh 主流程有「回合开始 / 回合 settle / 工具出错」的内部事件，直接在那里 fire-and-forget POST——这通常是最小方案
2. **Cordis 插件**：按 profile 安装 npm 包，重一些，且要考虑安装/更新的幂等
3. **claude-code 风格 hooks 桥**：如果 dsh 支持（或有现成 bridge），直接复用 `~/.yierpet/hook.sh`

目标事件（按优先级）：
1. `Stop`（回合 settle，带 `{text: 最后回复}`）— 完成提醒 + 摘要
2. `PostToolUseFailure`（带 `{error}`）— 报错提醒
3. `UserPromptSubmit`（回合开始）— 状态复位
4. `PostToolUse` 心跳 — 可选，"工作中"展示更准

### B. 验证 TUI 鲸鱼娘

dsh TUI 是独立仓库 `~/Work/tools/dsh-TUI`，其中 `src/components/Whale.tsx` + `whaleFrames.ts` 是 TUI 原生鲸鱼娘。**未确认** TUI 鲸鱼娘的显隐受什么控制（settings.yaml 的 `pet.visible`？`~/.dsh/pet.json` 的 `display.visible`？还是 TUI 自己的配置）——读代码确认。

- 若 TUI 里鲸鱼娘仍显示：找到正确的关闭开关并处理
- 兜底手段：`~/.dsh/pet.json` 的 `display.visible` 目前是 `true`，可翻转为 `false`（依据：`~/.dsh/profiles/*/node_modules/@linxin666/dsh-pet/lib/client.js` 读 `display.visible ?? true`）

## 验收标准

1. dsh 实跑一轮 → YierPet 出完成气泡，第二行有『最后回复』摘要
2. dsh 触发一次错误 → 报错气泡（可选）
3. dsh TUI 里不再出现鲸鱼娘
4. dsh 原有功能零影响：不引入运行时硬依赖（YierPet 不在也完全正常）、不改默认行为

## 环境事实

- dsh：`@deepseek-ai/dsh` rc.7，配置目录 `~/.dsh/`，源码 `~/Work/tools/deepseek-harness`
- 本机有 bun、node v24（nvm）；YierPet 是 Swift 项目但你不需要碰 Swift 代码
- 改 `~/.dsh/` 下任何配置：先备份、操作幂等、不动无关条目
- 用户偏好：最小方案优先（能一行不写十行），方案拿不准时先问用户再动手
