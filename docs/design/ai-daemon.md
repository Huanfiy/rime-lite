# AI 智能候补 — 结构与运行设计

| 项 | 内容 |
| --- | --- |
| 状态 | 现行（D-17–D-23，见 [architecture.md](architecture.md) §2） |
| 定位 | AI 候补通路的结构、契约、约束与运维；参数值与协议正文在引用文件处，本文不复述 |

## 1. 行为定义

组词中按 `Tab` 显式请求（无长度门槛）：daemon 依据会话上下文（近期上屏 ≤ 6 条）经 OpenAI 兼容 API 生成 ≤ 3 条候补——首项为当前段拼音转换；普通输入的其余项可延伸预测，表情意图的其余项改为匹配语义的 emoji / 颜文字（D-23）。候补注入候选栏首位（⚡ 标记），选中即整段上屏。AI 候补不受本地词库限制；本地候选跟随其后，重文由 uniquifier 消重。纯触发式（D-21）：不按 `Tab` 零请求零上云。

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
- **两拍触发**（D-20 / D-21）：`Tab` 命中缓存即时展示；未命中则发请求并有界等待（250ms），到点未回亮「⚡…」段提示，约一个 API 周期后再按即命中。长按 `Tab` = 轮询收割（有界等待带 1s 冷却，不积压事件队列）。
- **纯触发式**（D-21）：请求仅由触发键产生；隐私边界即「不按 `Tab` 零上云」。
- **键位**：`Tab` 仅在组词状态被拦截；音节导航改为 `Shift+Tab` / `Alt+←→`（`default.yaml` key_binder）。
- **数据外发边界**：上屏文本仅进本机 daemon 内存；仅在按触发键时，把上下文尾部（≤ 80 字）+ 已选前缀 + 当前段拼音 + 本地候选参考送云端。

## 4. 性能、降级与红线

- 红线（D-19）：热路径 Lua ≤ 0.1ms/键；filter 只查表注入，不组装请求。
- 端到端延迟由模型推理主导；进程内 UDS 为微秒级。
- 调度（D-20 / D-21）：所有请求直达并发槽（`max_concurrency` 默认 3）+ 同 key 在途防重；上屏作废在队请求，在途 API 不中断（回包按 key 失配丢弃）。
- 降级（全部静默，体验 = 原生）：daemon 缺席 → connect 失败 + 2s 重连冷却；luasocket 等不可用 → setup 一次失败后本进程内永久禁用；空结果 / 超时 → 丢弃。

## 5. 关键实现约束（维护前必读）

- **loadlib 前置**：librime 以 `dlopen(RTLD_LOCAL)` 加载插件，liblua 符号不进全局符号表，而 Debian lua-socket 的 C 模块依赖宿主导出 Lua 符号——`glue.lua` 必须先 `package.loadlib(<liblua>, "*")` 再 `require("socket")`，否则报 `undefined symbol: lua_gettop`。默认路径为 x86_64 的 liblua5.4，其他机器用环境变量 `RIME_AI_LUALIB` 覆盖。
- **系统依赖**：`librime-plugin-lua`（漏装则 glue `setup()` 静默失败并本进程永久禁用）、`lua-socket`；daemon 仅 Python 标准库。octagram 不走本轨道（architecture.md §8）。
- **惰性候选流**：filter 是懒执行候选流的一环，前端每页只拉 5 个候选——注入决策必须在首个候选到达时完成，写在迭代循环之后的代码在正常打字时不会执行。
- **luasocket 是阻塞库**：「异步」由 `settimeout(0)` + 缓存实现，无线程；阻塞等待仅触发键路径允许且有界。
- **消重契约**：filters 顺序必须是 `ai.suggest` → `uniquifier`。
- **缓存键**：`输入串@翻译段起点`；响应按 key 精确匹配。请求的 `pinyin` 只含当前翻译段（`prefix` 另携带已选文本），选定首词后不重复前缀。
- **段提示重绘**：「⚡…」仅写 `Segment.prompt`，依赖 fcitx5 每键后重绘预编辑区；后续按键会重建分段并清除提示。
- **等待冷却**：trigger 有界等待带 1s 冷却（`WAIT_COOLDOWN`），避免长按每个重复事件都阻塞 250ms。
- **已选前缀提取**：`glue.selected_prefix` 从 preedit 剥尾部 ascii 拼音；前缀以 ascii 词结尾时会被一并剥掉，仅损失提示语境。

## 6. 运维

- 服务管理：`./run.sh daemon status|restart|logs`。journal 中每条 `suggest` 的延迟 / 产出 / token 是「AI 是否在工作」的地面真相。
- 调参：模型 / 并发 / 上下文改 `~/.config/rime-candidate-daemon/config.json` 后 `./run.sh daemon restart`；触发键 / 等待 / top_k 改 `rime/pinyin.schema.yaml` 的 `ai_suggest` 段后 `./run.sh restart`。
- 新机器：`./run.sh setup` → `./run.sh apikey set` → `./run.sh restart`。现役状态以 `./run.sh status` 为准。
- 密钥：仅存 daemon 配置文件（0600）；写入与轮换走 `./run.sh apikey set`。

## 7. 边界与非目标

- 候补锚定当前组词；无组词状态的「下一句预测」在 librime 没有实现通道。
- 不做自动预取、不做每键同步调用、不做云端结果自动弹出。
- 高推理量模型不适合本负载；模型更换走 daemon 配置，协议与结构不变。

## 8. 演进点

- 候补口径：daemon 的 `SYSTEM_PROMPT` 单处修改。
- 协议变更：需同步 `rime/lua/ai/glue.lua` 与 daemon，并更新 README 协议正文与版本号。
- M2（未做，不阻塞使用）：socket activation 常驻优化（现为常驻服务）。
