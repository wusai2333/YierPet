# dsh-yierpet-sentinel

把 [dsh](https://github.com/deepseek-ai/deepseek-harness) 的生命周期事件推给
[YierPet](../..) 桌宠哨兵：等确认 / 完成 / 报错时气泡提醒。

dsh 侧唯一改动就是这个 Cordis 插件——它监听 dsh 的 `session/event` 事件流
（内置宠物用的同一条缝），fire-and-forget 转发：

| dsh 事件 | YierPet hook | body |
|---|---|---|
| `turn/start` | `UserPromptSubmit` | — |
| `tool/result` | `PostToolUse`（心跳）/ `PostToolUseFailure` | `{error}` |
| `approval/asked` | `PermissionRequest` | `{message}` |
| `turn/end` completed | `Stop` | `{text: 最后一条回复}` |
| `turn/end` error | `PostToolUseFailure` | `{error}` |
| `session/disposed` | `SessionEnd` | — |

铁律：1 秒超时、所有错误静默、绝不阻塞 dsh；`~/.yierpet/endpoint` 不存在
（YierPet 没运行）时直接跳过。子 agent 会话不打扰（其审批除外），主回合的
Stop 已覆盖用户可见的完成时刻。

## 安装

```sh
dsh plugin --profile web add file:/Users/wusai/Work/tools/YierPet/integrations/dsh-sentinel
```

（或在 dsh 会话里用 market_install；装完重启 dsh 生效。TUI 用户同样装进
`dsh-tui` profile。）

## 自检

```sh
node --test test.js                                    # 映射逻辑
printf '{"text":"dsh 接入测试"}' | ~/.yierpet/hook.sh dsh Stop   # 端到端（YierPet 运行时）
```
