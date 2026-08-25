# 语音输入组件（voice-daemon）实施计划

| 项 | 内容 |
| --- | --- |
| 状态 | 待实施（M0 探针未开始）；落地后以 D-27 记入 [architecture.md](../design/architecture.md) §2，本文清理 |
| 定位 | 语音输入组件的形态选型、实施步骤与验证方案 |

## 1. 背景

诉求：语音输入要与现有 AI 候补组件**平级**——插件式、用户按键主动触发、高内聚低耦合、可独立开发调试、核心代码入库（模型与环境不入库）。

现状判断（评估对象 VocoType-linux）：

- **VocoType 的架构不可复用**。其 fcitx5 版本注册为独立 InputMethod，非 F9 按键全部经 Unix socket 同步转发给 backend 内的第二个 librime 实例（`fcitx5/addon/ipc_client.cpp:25-80`，无超时、阻塞 fcitx 主线程），并与 fcitx5-rime 争抢 `rime/pinyin.userdb/` 的 LevelDB 排它锁。它是输入法替代品，不是插件。许可为 GPL-3.0，代码不拷入本仓库。
- **可复用的是技术选型**：`funasr_onnx==0.4.1` + Paraformer-large / FSMN-VAD / CT-Transformer 三个 ONNX 模型（modelscope 下载）+ `sounddevice` 采集，纯 CPU、离线、约 700MB 常驻。前提：Python 3、X11、`xdotool`、麦克风。
- **可复用的是本仓库 AI 组件的形态**：`rime/lua/ai/` ↔ UDS ↔ `services/candidate-daemon/` ↔ systemd 用户服务，配置在 `~/.config/`，代码入库。语音组件按同一形态复制一套即可。

必须额外解决的一处差异：AI 候补的产物天然是「候选」，语音的产物要在**空组词状态**下产生；而 librime 无异步刷新通道（D-17 / D-21），librime-lua 1.10 也**未暴露 `Engine:commit_text`**（仅有 `Context:get_commit_text`）。因此语音文本必须经「占位码 segment → lua_translator 产候选 → 用户确认上屏」的路径，并由 daemon 侧发唤醒脉冲替代第二拍按键。

目标形态：按住 F9 说话 → 松开 → 识别文本以 🎤 候选出现在候选栏 → 空格上屏 / Esc 丢弃；daemon 缺席时 F9 无副作用，输入体验退回原生。

## 2. 与 AI 组件的对照（平级形态）

| 维度   | AI 候补（现行）                                        | 语音（本计划）                                          |
| ---- | ------------------------------------------------ | ------------------------------------------------ |
| Rime 侧 | `rime/lua/ai/{trigger,suggest,glue}.lua`         | `rime/lua/voice/{trigger,insert,glue}.lua`       |
| 挂载点  | processor + filter                               | processor + **translator**（不加 filter，D-19 条文不受影响） |
| 触发键  | 组词中 `Tab`                                        | 任意状态 `F9`（PTT 按住）                                 |
| IPC  | NDJSON over UDS，`$XDG_RUNTIME_DIR/rime-candidate-daemon.sock` | NDJSON over UDS，`$XDG_RUNTIME_DIR/rime-voice-daemon.sock` |
| 服务   | `rime-candidate-daemon`（纯标准库）                    | `rime-voice-daemon`（需仓库外 venv：funasr_onnx / sounddevice） |
| 配置   | `~/.config/rime-candidate-daemon/config.json`     | `~/.config/rime-voice-daemon/config.json`（无密钥）   |
| 降级   | connect 失败 µs 级返回                                 | 同左，F9 静默无操作                                       |

**耦合决策**：`voice/glue.lua` 复制 `ai/glue.lua` 的 socket 层（loadlib 前置、`settimeout(0)`、有界 wait、重连冷却），**不抽公共层、不改动已验收的 AI 代码**。代价是约 80 行样板重复，换来两个组件互不影响、可独立调试。合并为共享 `uds.lua` 记作演进点，不进首版。

## 3. M0 — 探针（必须先做，阻塞后续实施）

临时探针不入库，验证后删除。写一个 `rime/lua/voice/probe.lua`（processor），把 `key_event:repr()`、`key_event:release()`、时间戳追加到 `/tmp/voice-probe.log`，临时挂到 `rime/pinyin.schema.yaml` 的 processors，`tools/deploy` + `fcitx5 -rd` 后真机操作。

验收判据：

1. **release 是否到达**：按住 F9 约 2s 再松开，日志末尾出现 release 事件 → PTT 成立。
2. **auto-repeat 形态**：长按期间若 press / release 成对重复出现，则无法区分「真松开」→ **降级为 toggle**（按一下开始、再按一下结束），由 `voice/mode` 配置项承载，其余设计不变。（已知长按 `Tab` 时重复 press 会到达 processor，见 [ai-daemon.md](../design/ai-daemon.md) §3；release 侧未验证。）
3. **空组词状态下 processor 是否被调用**：不组词时按 F9 应有日志。
4. **占位码能否形成 segment**：临时在 `recognizer/patterns` 加 `voice` 模式 + 一个返回固定候选的最小 translator，在 processor 里 `ctx:push_input(marker)`，确认候选栏出现该候选、preedit 可控、`ctx:clear()` 可清除。marker 首选 `` `v ``（用户几乎不会打出；`push_input` 绕过 processor 链，punctuator 不参与）。

判据 4 不成立时停止实施并重新决策（备选：daemon 侧 `xdotool type` 直接注入文本，但那会离开 Rime 通路，需重新拍板）。

## 4. M1 — 实施

### 4.1 `services/voice-daemon/voice-daemon.py`（约 250 行，仓库外 venv 运行）

- UDS server，socket `$XDG_RUNTIME_DIR/rime-voice-daemon.sock`（0600），NDJSON 逐行协议；结构照抄 `services/candidate-daemon/candidate-daemon.py` 的 accept / handle 骨架。
- 状态机 idle / recording：`start` 开 `sounddevice.InputStream`（16k、mono、int16）累积到内存；`stop` 关流 → VAD → ASR → 标点 → 回包；`cancel` 丢弃。
- ASR 直接调 `funasr_onnx` 公开 API（Paraformer + FSMN VAD + CT-Transformer），**不拷贝 VocoType 代码**（GPL-3.0 传染）。模型由 modelscope 下载到 `~/.cache/modelscope`，README 给命令。
- `provider`：`funasr` / `mock`（mock 不加载模型、返回固定文本 + 可配延迟，与 candidate-daemon 的 mock 同构，用于链路验证）。
- **唤醒脉冲**：识别完成后 `xdotool key <keysym>`（默认 `F9`，可配可关）。复用 F9 而非冷门键，是因为 processor 在 waiting 态总会吞掉 F9，脉冲不会泄漏给应用。
- CLI 调试：`--once N` 录 N 秒直接打印识别结果与耗时（完全脱离 Rime）；`--socket` 覆盖路径；`--debug` 前台日志。
- 每次 `stop` 记一条日志（时长、识别耗时、字数），作为「语音是否在工作」的地面真相。

### 4.2 服务与配置（入库）

- `services/voice-daemon/config.example.json`：`provider` / `device` / `sample_rate` / `preload_model` / `wake_pulse`（keysym 或 null）/ `max_record_s`。
- `services/voice-daemon/rime-voice-daemon.service`：照 `rime-candidate-daemon.service` 写，`ExecStart` 指向仓库外 venv 的 python + 仓库内脚本；**需带 `Environment=DISPLAY=:0`**（或安装步骤里 `systemctl --user import-environment DISPLAY XAUTHORITY`），否则唤醒脉冲发不出去。
- `services/voice-daemon/README.md`：依赖（`lua-socket`、venv、模型下载）、协议正文、安装与运维命令、故障排查。

### 4.3 `rime/lua/voice/`（入库）

- `glue.lua`：复制 `rime/lua/ai/glue.lua:25-92` 的 setup / connect / send_line 与 drain / wait，去掉 AI 专有的 cache_key / request / commit，socket 路径改用 `RIME_VOICE_SOCKET` 环境变量覆盖。
- `trigger.lua`（processor）：状态机 idle → recording → waiting → idle。
  - F9 press 且 idle：组词中先 `ctx:commit()` 上屏当前候选，再 `ctx:push_input(marker)` + 发 `start`，`Segment.prompt` 置「🎤 录音中…」。
  - auto-repeat 的重复 press：状态机吞掉，不重复发指令（µs 级返回）。
  - F9 release：发 `stop`，进 waiting，有界等待 200ms（仅触发键路径允许阻塞，沿用 D-17 既有口径，带冷却）；命中则 `ctx:refresh_non_confirmed_composition()`。
  - waiting 中的 F9 press（来自唤醒脉冲或用户）：视为收割 —— `drain()` + 查缓存 + refresh。
  - 未命中：`Segment.prompt` 亮「🎤…」，等脉冲或再按一次。
  - 环境不可用 / daemon 缺席：`kNoop` 直通，F9 交回应用。
- `insert.lua`（lua_translator）：首行 `if not seg:has_tag("voice") then return end` 早退；按状态产出候选——录音中 → 「🎤 录音中…」占位候选；结果就绪 → `Candidate("voice", seg.start, seg._end, text, "🎤")`，`candidate.preedit` 设为识别文本，选中即上屏（`editor/space: confirm` 已有）。

### 4.4 `rime/pinyin.schema.yaml`

- `processors` 增 `lua_processor@*voice.trigger`（紧邻 `lua_processor@*ai.trigger` 之后）。
- `translators` 增 `lua_translator@*voice.insert`。
- `recognizer` 段在 `import_preset: default` 基础上加 `patterns/voice`。
- 新增 `voice:` 段：`trigger_key`（默认 `F9`）、`mode`（`ptt` / `toggle`）、`marker`、`wait_ms`（默认 200）、`max_record_s`。

### 4.5 协议 v1.0（NDJSON over UDS）

```text
req : {"op":"start","id":N}
      {"op":"stop","id":N,"key":"<会话键>"}
      {"op":"cancel"}
      {"op":"ping"}
resp: {"id":N,"ok":true}
      {"key":"<原样回显>","text":"<识别文本>","ms":123}
      {"pong":true}
```

`key` 由 lua 侧按会话序号生成，回包按 key 精确匹配，过期结果天然丢弃（沿用 AI 通路的失配丢弃口径）。

### 4.6 文档回写（同轮提交，D-16）

- 新建 `docs/design/voice-daemon.md`：结构、交互契约、性能与降级、关键实现约束、运维、边界。
- `docs/design/architecture.md` §2：新增 D-27（语音组件形态与通路决策）。
- `AGENTS.md`：命令与禁区加一行语音通路指针，与 AI 通路并列。
- 本计划文件按 docs-rules「落地后搬入 design 并清理」处置。

## 5. 验证（本仓库的「测试」）

1. **M0 探针判据**（§3 四项），不通过不进 M1。
2. **staging 构建零 E**：`./run.sh verify`，schema 与 lua 挂载必须零 E 级日志。
3. **daemon 独立验证**：`voice-daemon.py --once 3` 说一句话，确认识别文本与耗时；`journalctl --user -u rime-voice-daemon -f` 观察常驻服务。
4. **mock 端到端**：`provider=mock`（不加载模型）走完 F9 按下 → 候选栏「录音中」→ 松开 → 唤醒脉冲 → 候选出现 → 空格上屏全链路。
5. **真机 PTT 抽查**：连续 3 句；确认 Esc 丢弃、组词中按 F9 先上屏再录音、`systemctl --user stop rime-voice-daemon` 后 F9 无副作用。
6. **热路径预算复核（D-19）**：AI processor + 语音 processor 同时在链上时每键开销仍 ≤ 0.1ms；语音不引入 filter，「filters 仅 uniquifier + ai.suggest」条文不变。

## 6. 边界与非目标

- 仅在 fcitx5-rime 为当前输入法且有输入焦点时可用；其它输入法 / 无 IM 的场景不覆盖。
- X11 限定（唤醒脉冲依赖 xdotool）。Wayland 下自动退化为两拍收割（松开后再按一次 F9），功能不丢。
- 不做流式实时识别（松开后整段识别）；不做热词 / 自定义词表适配；不做语音控制指令。
- 模型权重、venv、录音临时文件一律不入库（沿用运行态隔离约定）。

## 7. 风险与降级

| 风险                            | 处理                                                    |
| ----------------------------- | ----------------------------------------------------- |
| PTT 的 release / auto-repeat 行为未验证 | §3 判据 1-2；不成立则切 `mode: toggle`，交互从「按住」变「按两下」            |
| 占位码 segment 行为未验证             | §3 判据 4；不成立需重新决策上屏通路（备选 `xdotool type`，离开 Rime 通路，需拍板） |
| 模型常驻约 700MB、首次加载数秒            | `preload_model` 配置项；空闲卸载记作演进点                          |
| 唤醒脉冲落到非预期窗口（说话中切了窗口）          | 脉冲可配可关；关闭后退化为两拍收割                                      |
| systemd 用户服务无 DISPLAY 导致脉冲失效  | unit 内显式 `Environment=DISPLAY=:0`，README 写明             |
