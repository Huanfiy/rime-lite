# AI 候选 daemon 实施方案推导

| 项    | 内容                                                                 |
| ---- | ------------------------------------------------------------------ |
| 创建日期 | 2026-07-08                                                         |
| 状态   | 已落地——D-17 / D-18 / D-19 同日拍板并实现，M0/M1 验收见 [architecture.md](../../design/architecture.md) §12；仅剩 §9 的 M2 收尾 |
| 关联   | D-17 / D-18 / D-19（[architecture.md](../../design/architecture.md) §2）；运行说明 [services/candidate-daemon/README.md](../../../services/candidate-daemon/README.md) |
| 定位   | 实施过程推导（含 §2 socket 探针实测）；结论已落档 [design/ai-daemon.md](../../design/ai-daemon.md)（2026-07-08），本文件仅余过程记录，待 M2 按 docs-rules §4 清理 |

## 1. 边界条件（已定，不再讨论）

- **延迟模型（D-17）**：按需触发 + 异步预取。热路径任何情况下不等待 daemon；结果展示以专用触发键为主入口。
- **传输**：unix domain socket（实测依据见 §2）。
- **降级要求**：daemon 缺席 / 变慢 / 崩溃时，输入体验必须与现状完全一致（探针已证明降级路径成本 µs 级）。

## 2. socket 能力探针实测（2026-07-08，自 OQ-2 文档移入）

- 方法：librime 1.10.0 C API 按键探针路径（同阶段 2/3 验证），隔离 staging（`/tmp/rime-lua-probe/`），staging 副本 schema 挂 `lua_translator@probe_translator`，探针 Lua 对本机 echo 服务（unix socket + localhost TCP）做往返测评；零写入仓库与运行目录。
- 环境：librime-plugin-lua `1.10.0+dfsg1~git20230917-2build2`（动态链接系统 liblua5.4）；lua-socket `3.1.0-1`（`apt-get download` + `dpkg -x` 本地提取，未装入系统；模块自报 `_VERSION` 为 LuaSocket 3.0.0）。
- **结论：可行**。librime-lua 内可加载 luasocket 并完成本地 IPC 往返。
- **关键前置（不做即失败）**：librime 以 `dlopen(RTLD_LOCAL)` 加载插件，liblua5.4 符号不进全局符号表；而 Debian 打包的 Lua C 模块（`socket/core.so` 仅链接 libc）依赖宿主进程导出 Lua 符号，直接 `require("socket")` 报 `undefined symbol: lua_gettop`。绕路：先执行 `package.loadlib("/lib/x86_64-linux-gnu/liblua5.4.so.0", "*")`（`"*"` 模式 = RTLD_GLOBAL 仅链接、不取函数），再 require 即成功。
- 实测数据（64B 报文，200 次采样，Python echo 服务）：
  - unix domain socket：长连接 RTT p50 11.9µs / p95 15.0µs / max 24.1µs；冷连接全周期（connect+往返+close）p50 117.8µs；connect 17.9µs。
  - localhost TCP（对照）：RTT p50 20.0µs；冷连接全周期 p50 196.9µs。
  - 超时封顶有效：`settimeout(0.02)` 下服务端故意延迟 200ms，客户端 19.1ms 返回 timeout——「daemon 变慢但没死」场景可被硬性预算封顶，不会无限卡键。
  - daemon 缺席：connect 约 30µs 即失败返回——优雅降级（直接跳过）可行。
  - `require` 一次性 CPU 成本 0.29ms；探针全程零 E 级日志，`nihao` 对照候选不受影响。
- 边界：探针经 librime C API 进程内执行，与 fcitx5 同插件、同解释器、同加载路径，但未在 fcitx5 进程内复测（M0 真机抽查覆盖）；echo 只度量 IPC 传输下限，端到端延迟由 daemon 推理主导。
- 探针产物（rime.lua、driver.py、echo-server.py、probe-result.log）存于 `/tmp/rime-lua-probe/`，一次性中间产物不入库（docs-rules §3）；其中 driver.py 可复用于 M0 验证。

## 3. 组件与目录

```text
按键 → librime（fcitx5 进程内）
        ├─ lua_filter@*ai.rerank      热路径：非阻塞收包 + 查缓存 + 发预取（µs 级）
        ├─ lua_processor@*ai.trigger  触发键：有界等待在途结果 + 强制刷新展示
        └─ rime/lua/ai/glue.lua       共享：socket 连接、结果缓存、编解码
                  │  NDJSON over unix socket（$XDG_RUNTIME_DIR/rime-candidate-daemon.sock，0600）
        candidate-daemon（用户级后台服务，services/candidate-daemon/）
                  └─ 工作负载（§8 未拍板）+ 请求去抖/合并
```

- 仓库新增：`rime/lua/ai/`（glue / filter / processor）、`rime/lua/vendor/json.lua`（vendor rxi/json.lua 单文件纯 Lua，头注释记来源与版本，沿用 vendor 规范）、`services/candidate-daemon/`（daemon + systemd 用户单元）。
- schema 改动：`filters` 在 `uniquifier` 前插 `lua_filter@*ai.rerank`；`processors` 加触发键处理器（位置实现时定）；`switches` 增 `ai_suggest` 开关，off 时 filter 首行早退。
- 系统前置：`apt install lua-socket`（探针用的 dpkg -x 本地副本不用于常态运行）；Lua 入口保留 §2 的 loadlib 前置。

## 4. 热路径数据流与交互契约

每键（filter 内，全程非阻塞，预算 ≤ 0.1ms）：

1. **收**：`settimeout(0)` 循环收包（上限 8 条），结果按 input 精确键入缓存；
2. **查**：缓存命中当前 input → 应用重排 / 插入候选；未命中 → 原样放行；
3. **发**：input 长度 ≥ N 且该 input 未在途 → 非阻塞发送预取请求；失败静默丢弃，2s 重连冷却。

触发键（processor）：

- 缓存命中 → `context:refresh_non_confirmed_composition()` 强制重跑 filter → 即时展示；
- 未命中 → 对在途结果有界等待（≤ 50ms）后重查，仍无则 noop（再按一次通常已命中）。

体验契约（写给未来读者，防止预期错位）：

- 连续输入期间候选与手感与现状**完全一致**，AI 结果不会自己跳出来——librime 候选窗无异步刷新通道，这是引擎约束而非实现取舍；
- 「看 AI 结果」是显式动作 = 按触发键；异步预取的价值是让这个动作几乎总是瞬时命中（结果在打字间隙已算好）；
- 回删到历史输入状态时缓存天然命中。

## 5. 协议 v1 草案（NDJSON over UDS）

```text
req : {"v":1,"id":<单调递增>,"op":"suggest","input":"<原始编码>","cands":[["文本",quality], … ≤10]}
resp: {"v":1,"id":…,"input":"<原样回显>","order":[候选下标重排…],"insert":[{"pos":0,"text":"…","comment":"⚡"}]}
```

- 请求携带本地 top-K 候选 → daemon 无需接触 Rime 词库即可重排；
- 客户端按 `input` 精确匹配后才应用（天然丢弃过期结果）；`id` 单调递增供 daemon 侧丢弃过期请求；
- daemon 去抖 ~60ms、仅计算每连接最新请求——连打时只算稳定态，省推理；
- 冻结时机：M0 通路验证结束时随实测数据一并定稿。

## 6. 生命周期与多机

- systemd 用户单元 + socket activation：不用时不常驻，首连拉起；拉起窗口内请求静默丢弃（降级即原生体验）。
- 多机（D-6）：daemon 代码与单元文件经 Git 同步；模型文件不入库（`.gitignore`），各机自取，安装步骤记 `services/candidate-daemon/` 内 README。

## 7. 红线治理

现行红线「热路径零 Lua」（CLAUDE.md / fact.md）与本功能定义性冲突；architecture.md §8 预留的 lua 槽位即为此豁免路径。处理方式：**实现落地的同一提交内**将红线修订为预算制——「热路径 Lua 预算 ≤ 0.1ms/键（实测口径）；filters 仅 uniquifier + ai.rerank；`ai_suggest` off 时早退」，作为新 D-n 拍板，不提前改。

## 8. 工作负载（方向已定，参数待拍板）

**方向（2026-07-08 用户拍板）**：语义级「懂我」的候选——LLM 重排为主（生成式补全可后续叠加），经 OpenAI 兼容 API 走云端模型。octagram 对照就此出结论：其局部 n-gram 能力不覆盖「跨句上下文 + 语义理解」诉求，不走该轨道（如需可另作离线补充，与本轨道无关）。

daemon 角色相应明确为：UDS ↔ HTTPS 桥 + 请求去抖合并 + 会话上下文维护（经 `commit_notifier` 收集近期上屏文本，作为「懂我」的上下文来源）+ API key 托管（daemon 侧配置文件，**不入库**）。

**API 实测（2026-07-08，自建 OpenAI 兼容中转，测试期临时 key）**：

- 可用模型：gpt-5.3-codex-spark / gpt-5.4 / gpt-5.5（另有 image 模型，无 mini/nano 级轻量模型）。
- 重排质量：3 个用例（无上下文基线 + 「zhongduan」双语境消歧）× 3 模型全部命中——嵌入式语境出「中断」、命令行语境出「终端」，验证了 LLM 重排对语境消歧的价值。
- 重排延迟（约 400 token 输入 + 短输出，持久连接）：gpt-5.4 p50 ≈ 2.2s（min 1.7s）、gpt-5.5 p50 ≈ 2.3s、spark p50 ≈ 1.4s；流式 TTFT 1.3~1.9s，对短输出无实质收益；`reasoning_effort` 仅支持 low 及以上，low 未显著降延迟。
- 网络底座（本机 → 中转）：TLS 握手 ~0.33s（daemon 长连接可摊销），models 接口 TTFB ~0.55s。

**延迟结论**：端到端 **1.4~3s 量级**，比 notes 初稿假设的本地小模型（20~100ms）高一个数量级以上。设计影响：

- D-17 的异步预取从「优选」变为「唯一可行」——触发键现场发请求再等待完全不可用；
- 触发键有界等待（§4 的 ≤50ms）只对「结果已在途且将至」有意义，常态依赖预取提前量：打完字到伸手按触发键的人类间隙（0.5~1s）+ daemon 去抖后立即发起，命中率取决于「停止输入 → 按键」间隔 ≥ API 延迟；打字节奏快时首按未命中、再按命中是预期行为；
- 预取策略必须克制（隐私 + 成本 + 延迟三重原因）：仅稳定态（去抖 ≥300ms）+ 输入长度 ≥ N 才发起；`ai_suggest` 开关默认关，按场景手动开。

**隐私边界（预取模式的代价，需正视）**：预取 = 把输入稳定态（拼音 + 本地候选 + 近期上屏上下文）自动发往云端中转。缓解手段：开关默认关、ascii_mode 下不发、长度门槛、daemon 侧可配置 trigger-only 模式（仅触发键才发请求，牺牲命中换隐私）。

**剩余待拍板（M1 范围）**：模型选择（spark 最快但输出含大量推理 token，5.4 质量/延迟均衡）、预取 vs trigger-only 默认值、prompt v1 与上下文窗口大小。凑齐 M0 通路数据后一并定为 D-18。

> 2026-07-08 已拍板（D-18，用户口径「LLM 已经够智能，选最快的配置」）：模型 `gpt-5.3-codex-spark`、预取默认开（开关关闭即 trigger-only）、prompt v1 为精简重排式（≈110 prompt tokens）。
>
> 同日演进（用户验收反馈「要的是猜后续输入的候补，重排浪费 AI 能力」）：工作负载从「重排本地候选」改为**生成式智能候补**——daemon 生成 ≤3 条完整内容（拼音转换 + 延伸预测，不受词库限制）注入候选栏首位，本地候选降级为 prompt 参考提示；协议 resp 从 `order`（重排序）换为 `cands`（生成文本），filter 从重排改为注入（`ai/rerank.lua` → `ai/suggest.lua`），uniquifier 消重。参数最终态见 architecture.md §2 D-18 行。本文件 §3-§6 保留的是重排式初稿描述，最终形态以 architecture.md 与 services/candidate-daemon/README.md 为准（本文件 M2 清理）。

## 9. 里程碑

- [x] **M0 通路验证**（2026-07-08）：mock daemon + 完整 Lua glue；staging 构建零 E；降级 / 自动预取 / 重排应用 / commit 通报全过；热路径开销实测 ≤ +0.03ms/键（预算 0.1ms，D-19）。协议 v1 冻结。真机后修订：初版预取误置于惰性流耗尽后（正常打字不执行），当日发现并修复复验（见 architecture.md §12 修订注）。
- [x] **M1 真负载**（2026-07-08）：接入真 API（D-18 参数）；重排式先通过（daemon 级双语境消歧 1.7~1.8s + 引擎全链路 e2e），同日演进为生成式候补后复验——e2e 得 `中断处理 / 中断处理程序 / 中断服务程序`（语境 + 延伸），生产冒烟 `gaotie` +「出差」上下文 → `高铁票 / 高铁去上海 / 高铁二等座`；systemd 服务已随负载更新重启。
- **M2 收尾**（未做，不阻塞使用）：socket activation（现为常驻服务）、真机 fcitx5 抽查回写、`design/ai-daemon.md` 落档、本文件与 OQ-2 文件清理。（spark 方差问题已于当日兑现为默认模型调整 `gpt-5.4`+`low`，触发键同日 `Ctrl+t`→`Tab`，见 architecture.md §12。）

## 10. 已知边界

- librime 无异步候选刷新通道 → 「结果自动出现」引擎层面不可实现（§4 契约即由此而来）；
- luasocket 为阻塞式库，「异步」由 `settimeout(0)` + 缓存实现，无线程；
- 端到端延迟由推理主导，IPC 占比 <0.1%（§2）；云端 API 实测 1.4~3s（§8），预取提前量是体验成立的前提；
- API key 与中转 endpoint 属敏感配置：daemon 侧配置文件承载，不进 Git（`.gitignore` 覆盖），文档不记录具体 URL 与 key。
