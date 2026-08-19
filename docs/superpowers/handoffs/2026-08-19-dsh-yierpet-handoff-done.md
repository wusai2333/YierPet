# 完成记录：2026-08-19 dsh → YierPet 接入

对应交接：`2026-08-19-dsh-yierpet-handoff.md`。执行者：dsh 本体。

## A. 事件接入（已完成）

接入点不是 claude-code hook 桥（未随 CLI 安装），而是 dsh 内部
`ctx.on('session/event')` 事件流——内置宠物插件消费的同一条缝。

- 新 Cordis 插件：`integrations/dsh-sentinel/`（本仓库），零依赖、纯 host 侧
- 映射：turn/start→UserPromptSubmit；tool/result→PostToolUse/PostToolUseFailure{error}；
  approval/asked→PermissionRequest{message}；turn/end(completed)→Stop{text:最后回复}；
  turn/end(error)→PostToolUseFailure；session/disposed→SessionEnd
- 铁律：1s 超时、全错误静默、endpoint 文件缺失即跳过；子 agent 会话静默（审批除外）
- 已装入 profile：`web`、`dsh-tui`（`dsh plugin --profile <p> add file:…`，
  bundles 自动并入，`--dump-config` 两边都验证过）。desktop 为裸 profile，未装
- 注：`market_install` 预检被 profile 遗留的 `pnpm.onlyBuiltDependencies` 字段误判拦死，
  故直接走了其底层的官方 `dsh plugin add`
- 自检：`node --test integrations/dsh-sentinel/test.js`（7 过）+ mock endpoint
  冒烟（6 事件全中、子 agent 静默、无 endpoint 静默）+ `hook.sh` 端到端 200

**待用户确认**：重启 dsh 后实跑一轮，应见完成气泡带摘要（插件随 boot 挂载）。

## B. TUI 鲸鱼娘（已完成）

调查结论：TUI 鲸鱼是 `dsh-TUI` 的 LogoV2 开屏品牌图，只受终端宽度控制，
与 `pet.visible` / `pet.json` 完全无关（pet.json 只影响 web profile 的 dsh-pet
插件，而该插件已被 settings `pet.visible: false` 在 boot 时隐藏——无需兜底）。

处理：给 dsh-TUI 加了 `dsh-tui.whale` 设置开关（照抄 diffLayout 管线：
channel state/setter → plugin schema+apply+/settings 布尔项 → Chat → LogoHeader
→ LogoV2 `showWhale = whale && columns >= 64`，默认 true 不改他人行为），
重建了 lib（备份在 `/tmp/dsh-tui-lib-bak`），并在 `~/.dsh/settings.yaml`
写入 `dsh-tui: { whale: false }`（备份 `settings.yaml.whale-bak`）。

**待用户确认**：下次开 TUI，头部不再有鲸鱼；`/settings` 里可切回。

## 验收对照

1. 实跑一轮出完成气泡带摘要 — 机制全部验证，待重启后目视确认
2. 报错气泡 — 冒烟验证（PostToolUseFailure 带 error 文本）
3. TUI 无鲸鱼 — 代码路径+重建产物验证，待下次 TUI 目视确认
4. 零影响 — 无硬依赖、全静默、默认值不改行为、未动无关配置
