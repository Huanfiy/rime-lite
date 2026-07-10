# AI 智能候补 — 结构与运行设计

| 项    | 内容                                                        |
| ---- | --------------------------------------------------------- |
| 创建日期 | 2026-07-08                                                |
| 状态   | 现行（决策 D-17 / D-18 / D-19 / D-20 / D-21，见 [architecture.md](architecture.md) §2；验收记录同文件 §12） |
| 定位   | AI 候补通路的结构、契约、约束与运维；参数值与协议正文在引用文件处，本文不复述 |

## 1. 行为定义

组词中按 `Tab` 显式请求（无长度门槛，2026-07-10 起 `min_length: 1`——纯触发式下门槛失去保护对象）：daemon 依据会话上下文（近期上屏 ≤ 6 条）经 OpenAI 兼容 API 生成 ≤ 3 条候补——**当前段拼音转换 + 延伸预测**（如上屏「嵌入式系统」后输入 `zhongduan` → 「中断处理程序」），注入候选栏首位（⚡ 标记），选中即整段上屏。AI 候补不受本地词库限制；本地候选跟随其后，重文由 uniquifier 消重。纯触发式（D-21）：不按 `Tab` 零请求零上云，无自动预取。

## 2. 结构

```text
fcitx5（librime 进程内）
│
├─ rime/pinyin.schema.yaml           挂载与参数：ai_suggest 段、engine 列表
│   ├─ lua_processor@*ai.trigger     触发键（Tab，唯一请求入口）：命中缓存即刷新展示；
│   │                                未命中发请求 + 有界等待，到点未回亮「⚡…」段提示（两拍契约）
│   └─ lua_filter@*ai.suggest        热路径：收包 → 查缓存 → 命中注入（只注入不请求，全程非阻塞）
│         └─ rime/lua/ai/glue.lua    共享层：UDS 连接、结果缓存、收发；vendor/json.lua 编解码
│
│    NDJSON over unix socket（$XDG_RUNTIME_DIR/rime-candidate-daemon.sock，0600）
│
└─ services/candidate-daemon/candidate-daemon.py   systemd 用户服务 rime-candidate-daemon
      所有请求直达并发槽（max_concurrency，连接池；同 key 在途防重）；
      commit 作废在队请求
      → 组 prompt（会话上下文 + 已选前缀）→ OpenAI 兼容 API → 候补文本
      密钥与运行参数：~/.config/rime-candidate-daemon/config.json（0600，不入库）
```

协议 v1.3 与配置字段的正文：[services/candidate-daemon/README.md](../../services/candidate-daemon/README.md)。

## 3. 交互契约

- **连续输入零干扰**：filter 每键仅做非阻塞收包与查表（本会话从未按过触发键时直通透传）；AI 结果不会自行弹出——librime 无异步候选刷新通道，这是引擎级约束，也是「触发键」契约的根源（D-17）。
- **两拍触发**（D-20 引入，D-21 后为唯一通路）：`Tab` 命中缓存即时展示；未命中则发请求（直达 API）并有界等待（250ms，兜「即将落地」的结果），到点未回亮「⚡…」段提示，约一个 API 周期后再按即命中。长按 `Tab` = 轮询收割：键自动重复逐次收包查缓存，结果落地即展示（有界等待带 1s 冷却，重复事件仅 µs 级查表，不积压事件队列）。
- **纯触发式**（D-21，取代原 `ai_suggest` 开关的两档语义）：请求仅由触发键产生，隐私边界即「不按 `Tab` 零上云」；开关已从 switches 撤销。
- **键位让位**：`Tab` 仅在组词状态被拦截，其余场景行为不变；原「Tab 音节右移」绑定已撤销（`rime/default.yaml`），音节导航余 `Shift+Tab` / `Alt+←→`。
- **数据外发边界**：上屏文本仅进本机 daemon 内存（会话上下文队列）；仅在按触发键发起请求时，把上下文尾部（≤ 80 字）+ 已选前缀 + 当前段拼音 + 本地候选参考送云端。

## 4. 性能、降级与红线

- 红线（D-19 预算制）：热路径 Lua ≤ 0.1ms/键；M0 实测 AI 通路参与前后差 ≤ 0.04ms/键（[architecture.md](architecture.md) §12，D-21 后 filter 更轻：只查表注入，不再组装预取请求）。
- 延迟量级：进程内 UDS RTT p50 ≈ 12µs（2026-07-08 socket 探针）；端到端由模型推理主导，`gpt-5.4` + `low` 生成实测 2.7~4.8s。
- 调度（D-20 并发化，D-21 收敛为单路径）：所有请求直达并发槽（`max_concurrency` 默认 3，HTTP 连接池）+ 同 key 在途防重，端到端 = API 净耗时；上屏作废在队请求（组词态已变、结果注定失配），在途 API 不中断（回包由客户端按 key 失配丢弃）。auto 路径的音节门控与去抖已随自动预取一并移除。
- 降级路径（全部静默，输入体验 = 原生）：daemon 缺席 → connect 约 30µs 失败返回 + 2s 重连冷却；运行环境不可用（luasocket 缺失等）→ setup 一次失败后本进程内永久禁用；daemon 空结果 / 超时 → 丢弃。

## 5. 关键实现约束（维护前必读）

- **loadlib 前置**：librime 以 `dlopen(RTLD_LOCAL)` 加载插件，liblua5.4 符号不进全局符号表，而 Debian lua-socket 的 C 模块依赖宿主导出 Lua 符号——`glue.lua` 必须先 `package.loadlib("/lib/x86_64-linux-gnu/liblua5.4.so.0", "*")` 再 `require("socket")`，否则报 `undefined symbol: lua_gettop`（2026-07-08 探针实测）。
- **系统依赖**：`lua-socket`（apt 包）；daemon 仅 Python 标准库。
- **惰性候选流**：filter 是懒执行候选流的一环，前端每页只拉 5 个候选——注入决策必须在首个候选到达时完成，写在迭代循环之后的代码在正常打字时不会执行（教训记录见 architecture.md §12 修订注；D-21 后 filter 无预取，该约束仅剩注入一项）。
- **luasocket 是阻塞库**：「异步」由 `settimeout(0)` + 缓存实现，无线程；阻塞等待仅触发键路径允许且有界。
- **消重契约**：AI 候补与本地候选重文时的去重依赖 filters 顺序 `ai.suggest` → `uniquifier`，调整顺序会破坏该行为。
- **缓存键**：`输入串@翻译段起点`，区分整句与选定首词后的剩余段；响应按 key 精确匹配，过期结果天然失配丢弃。请求的 `pinyin` 字段只含当前翻译段（`prefix` 另携带已选文本），候补文本与注入跨度一致，选定首词后不重复前缀。
- **段提示重绘**：Tab 未命中的「⚡…」提示仅写 `Segment.prompt`，依赖 fcitx5 每键后重绘预编辑区（2026-07-09 真机抽查确认）；后续按键 / 刷新组句会重建分段并自然清除提示。
- **等待冷却**：trigger 的有界等待带 1s 冷却（`WAIT_COOLDOWN`），防止长按时自动重复的键事件每个都阻塞 250ms 造成队列积压——长按场景由此退化为 µs 级轮询。
- **已选前缀提取**：`glue.selected_prefix` 从 preedit 文本剥尾部 ascii 拼音得到前缀；前缀以 ascii 词结尾（选定英文候选）时会被一并剥掉，仅损失提示语境，无正确性影响。

## 6. 运维

- 服务管理：`systemctl --user status|restart rime-candidate-daemon`；日志 `journalctl --user -u rime-candidate-daemon -f`（每条 `suggest` 含延迟、产出与 token 用量，是「AI 是否在工作」的地面真相）。
- 调参：模型 / 并发上限 / 上下文规模改 `~/.config/rime-candidate-daemon/config.json` 后 restart 服务，不动仓库；触发键 / 长度阈值 / 等待时长改 `rime/pinyin.schema.yaml` 的 `ai_suggest` 段后重新部署。
- 新机器接入：`sudo apt install lua-socket` → 按 [README](../../services/candidate-daemon/README.md) 建配置与 systemd 单元 → `tools/deploy` + `fcitx5 -rd`。
- 密钥卫生：仅存 daemon 配置文件（0600）；严禁写入仓库任何文件（CLAUDE.md 禁区）；泄露即轮换。

## 7. 边界与非目标

- 候补锚定当前组词：转换与延伸以已敲入的拼音为锚点，触发无长度门槛，但输入越短预测自由度越大、候补越靠猜；无组词状态的「下一句预测」（ghost text 式）在 librime 没有实现通道，不属本设计目标。
- 不做自动预取（D-21 撤销 D-18/D-20 的 auto 路径：预取结果无法自行展示，正常打字节奏下几乎总在上屏后作废，只烧 token 不产出）；不做每键同步调用（OQ-2 选项 3 已否决），不做云端结果自动弹出。
- 高推理量模型（spark 类）不适合本负载（token 烧量大、时延方差 1.7~7s，见 architecture.md §12）；模型更换走 daemon 配置，协议与结构不变。

## 8. 演进点

- 候补口径（条数、延伸长度、风格）：daemon 的 `SYSTEM_PROMPT` 单处修改。
- 协议变更：需同步 `rime/lua/ai/glue.lua` 与 daemon，并更新 README 协议正文与版本号。
- M2 收尾（未做，不阻塞使用）：socket activation 常驻优化（现为常驻服务）。
