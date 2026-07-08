# AI 智能候补 — 结构与运行设计

| 项    | 内容                                                        |
| ---- | --------------------------------------------------------- |
| 创建日期 | 2026-07-08                                                |
| 状态   | 现行（决策 D-17 / D-18 / D-19，见 [architecture.md](architecture.md) §2；验收记录同文件 §12） |
| 定位   | AI 候补通路的结构、契约、约束与运维；参数值与协议正文在引用文件处，本文不复述 |

## 1. 行为定义

输入长度 ≥ 4 的组词稳定后，daemon 依据会话上下文（近期上屏 ≤ 6 条）经 OpenAI 兼容 API 生成 ≤ 3 条候补——**拼音整句转换 + 延伸预测**（如上屏「嵌入式系统」后输入 `zhongduan` → 「中断处理程序」），异步预取入客户端缓存；组词中按 `Tab` 将候补注入候选栏首位（⚡ 标记），选中即整段上屏。AI 候补不受本地词库限制；本地候选跟随其后，重文由 uniquifier 消重。

## 2. 结构

```text
fcitx5（librime 进程内）
│
├─ rime/pinyin.schema.yaml           挂载与参数：ai_suggest 段、switches、engine 列表
│   ├─ lua_processor@*ai.trigger     触发键（Tab）：命中缓存即刷新展示；未命中有界等待后吞键
│   └─ lua_filter@*ai.suggest        热路径：收包 → 查缓存注入 → 发预取（全程非阻塞）
│         └─ rime/lua/ai/glue.lua    共享层：UDS 连接、结果缓存、收发；vendor/json.lua 编解码
│
│    NDJSON over unix socket（$XDG_RUNTIME_DIR/rime-candidate-daemon.sock，0600）
│
└─ services/candidate-daemon/candidate-daemon.py   systemd 用户服务 rime-candidate-daemon
      去抖合并（连打只算稳定态）→ 组 prompt（含会话上下文）→ OpenAI 兼容 API → 候补文本
      密钥与运行参数：~/.config/rime-candidate-daemon/config.json（0600，不入库）
```

协议 v1.1 与配置字段的正文：[services/candidate-daemon/README.md](../../services/candidate-daemon/README.md)。

## 3. 交互契约

- **连续输入零干扰**：filter 每键仅做非阻塞收发与查表；AI 结果不会自行弹出——librime 无异步候选刷新通道，这是引擎级约束，也是「预取 + 触发键」契约的根源（D-17）。
- **两段式触发**：`Tab` 命中缓存即时展示；未命中则现场发请求并有界等待（250ms）后吞键无动作，稍候再按通常命中（端到端延迟秒级，见 §4）。
- **开关语义**（`ai_suggest`，默认开，F4 选单可切）：开 = 稳定态自动预取；关 = trigger-only 隐私模式——零自动外发，仅按 `Tab` 时显式请求。
- **键位让位**：`Tab` 仅在组词状态被拦截，其余场景行为不变；原「Tab 音节右移」绑定已撤销（`rime/default.yaml`），音节导航余 `Shift+Tab` / `Alt+←→`。
- **数据外发边界**：上屏文本仅进本机 daemon 内存（会话上下文队列）；仅在发起候补请求时，把上下文尾部（≤ 80 字）+ 当前拼音 + 本地候选参考送云端。

## 4. 性能、降级与红线

- 红线（D-19 预算制）：热路径 Lua ≤ 0.1ms/键；实测开关开/关差 ≤ 0.04ms/键（[architecture.md](architecture.md) §12）。
- 延迟量级：进程内 UDS RTT p50 ≈ 12µs（2026-07-08 socket 探针）；端到端由模型推理主导，`gpt-5.4` + `low` 生成实测 2.7~4.8s。
- 降级路径（全部静默，输入体验 = 原生）：daemon 缺席 → connect 约 30µs 失败返回 + 2s 重连冷却；运行环境不可用（luasocket 缺失等）→ setup 一次失败后本进程内永久禁用；daemon 空结果 / 超时 → 丢弃。

## 5. 关键实现约束（维护前必读）

- **loadlib 前置**：librime 以 `dlopen(RTLD_LOCAL)` 加载插件，liblua5.4 符号不进全局符号表，而 Debian lua-socket 的 C 模块依赖宿主导出 Lua 符号——`glue.lua` 必须先 `package.loadlib("/lib/x86_64-linux-gnu/liblua5.4.so.0", "*")` 再 `require("socket")`，否则报 `undefined symbol: lua_gettop`（2026-07-08 探针实测）。
- **系统依赖**：`lua-socket`（apt 包）；daemon 仅 Python 标准库。
- **惰性候选流**：filter 是懒执行候选流的一环，前端每页只拉 5 个候选——预取与注入决策必须在头部候选收齐时完成，写在迭代循环之后的代码在正常打字时不会执行（教训记录见 architecture.md §12 修订注）。
- **luasocket 是阻塞库**：「异步」由 `settimeout(0)` + 缓存实现，无线程；阻塞等待仅触发键路径允许且有界。
- **消重契约**：AI 候补与本地候选重文时的去重依赖 filters 顺序 `ai.suggest` → `uniquifier`，调整顺序会破坏该行为。
- **缓存键**：`输入串@翻译段起点`，区分整句与选定首词后的剩余段；响应按 key 精确匹配，过期结果天然失配丢弃。

## 6. 运维

- 服务管理：`systemctl --user status|restart rime-candidate-daemon`；日志 `journalctl --user -u rime-candidate-daemon -f`（每条 `suggest` 含延迟、产出与 token 用量，是「AI 是否在工作」的地面真相）。
- 调参：模型 / 去抖 / 上下文规模改 `~/.config/rime-candidate-daemon/config.json` 后 restart 服务，不动仓库；触发键 / 长度阈值 / 等待时长改 `rime/pinyin.schema.yaml` 的 `ai_suggest` 段后重新部署。
- 新机器接入：`sudo apt install lua-socket` → 按 [README](../../services/candidate-daemon/README.md) 建配置与 systemd 单元 → `tools/deploy` + `fcitx5 -rd`。
- 密钥卫生：仅存 daemon 配置文件（0600）；严禁写入仓库任何文件（CLAUDE.md 禁区）；泄露即轮换。

## 7. 边界与非目标

- 候补锚定当前组词：需已敲入下一段内容的拼音开头（≥ 4 字母）才有转换与延伸的锚点；无组词状态的「下一句预测」（ghost text 式）在 librime 没有实现通道，不属本设计目标。
- 不做每键同步调用（OQ-2 选项 3 已否决），不做云端结果自动弹出。
- 高推理量模型（spark 类）不适合本负载（token 烧量大、时延方差 1.7~7s，见 architecture.md §12）；模型更换走 daemon 配置，协议与结构不变。

## 8. 演进点

- 候补口径（条数、延伸长度、风格）：daemon 的 `SYSTEM_PROMPT` 单处修改。
- 协议变更：需同步 `rime/lua/ai/glue.lua` 与 daemon，并更新 README 协议正文与版本号。
- M2 收尾（未做，不阻塞使用）：socket activation、真机体验抽查回写、notes 过程文件清理。
