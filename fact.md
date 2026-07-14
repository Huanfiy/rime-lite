# rime-lite 事实清单

| 项    | 内容                                              |
| ---- | ----------------------------------------------- |
| 更新日期 | 2026-07-14                                      |
| 定位   | 已决事项与当前状态的速查层；设计依据与推导以 [docs/design/](docs/design/) 为准 |

## 工程定位

- 个人最小 Rime 全拼输入方案：`rime/` 整目录即部署单元，Git 全量管理，无构建层（源文件即 Rime 可读文件）。
- 部署平台仅 fcitx5；本机环境 librime 1.10.0（`librime1t64 1.10.0+dfsg1-2build2`）、fcitx5-rime 5.1.4（Ubuntu 系统仓库）。
- 共享数据依赖仅 `/usr/share/rime-data`（librime-data 包）；对 rime-ice 工程无运行时路径依赖（D-4）。

## 部署拓扑（2026-07-02 定型）

- `~/.local/share/fcitx5` 为真实目录，其中仅两个软链接：`rime` → 当前激活工程配置目录（现为本仓库 `rime/`）；`themes` → `/home/huan/sync/pc_cfg/fcitx5/themes`。
- 工程切换 = 重指 `rime` 软链接：`tools/deploy`（激活本工程）、`--to <dir>`（切他工程）、`--status`（查看）、`--yes`（免确认）；切换后执行 `fcitx5 -rd` 生效。
- 备胎工程 rime-ice 位于 `/home/huan/sync/rime-ice`（远端 github:Huanfiy/rime-ice，退役前最终状态已推送）；rime-lite 稳定运行前不删除。

## 输入方案

- 启用方案仅 `pinyin`（全拼）；melt_eng 仅作词库挂载出英文候选，不作独立方案（2026-07-02 调整，git `e4aab2b`）；候选每页 5 个。
- 性能红线为预算制（D-19，2026-07-08 修订）：热路径 Lua 预算 ≤ 0.1ms/键（实测差值 ≤ 0.04ms）；filters 仅 `uniquifier` + `ai.suggest`；零 OpenCC filter 不变。
- AI 智能候补（D-18，2026-07-08 落地；D-21 起纯触发式）：组词中按 `Tab` 显式请求（无长度门槛，2026-07-10 起 `min_length: 1`），daemon 按会话上下文生成 ≤ 3 条候补（当前段转换 + 延伸预测，不受本地词库限制）注入候选栏首位（⚡ 标记，选中即整段上屏）；`rime/lua/ai/` ↔ unix socket ↔ `services/candidate-daemon/`（systemd 用户服务）↔ OpenAI 兼容 API；不按 `Tab` 零请求零上云，无自动预取、无开关（D-21 撤销）；Tab 两拍契约（命中缓存即展示；未命中亮 `⚡…` 提示、约一个 API 周期后再按即命中，长按 = 轮询收割）；daemon 缺席自动降级为原生体验。密钥在 `~/.config/rime-candidate-daemon/config.json`（不入库）。协议 v1.3（2026-07-09，D-21）。结构与契约见 [docs/design/ai-daemon.md](docs/design/ai-daemon.md)。
- 词库挂载链：`pinyin.dict.yaml` 的 `import_tables` = `cn_dicts/8105`（字表）+ `cn_dicts/base`（基础词库）+ `cn_dicts/embedded`（领域词库，602 条）+ `cn_dicts/mydict`（个人词库，46 条）；另含 26 个大写字母词条。
- `custom_phrase.txt`：个人固定短语（缩写码，如 `gpio` → GPIO、`zkb` → 占空比），`initial_quality: 99` 置顶。
- 本机学习：`enable_user_dict: true`，产出 `rime/pinyin.userdb/`（运行态，不进 Git）。

## 已决事项（详情见 [docs/design/architecture.md](docs/design/architecture.md) §2）

- D-1：不自建输入事件层；userdb 仅作本机学习缓存，稳定词条走「导出 → 审核 → 晋升静态词库 → Git」。
- D-2：首轮晋升分析源仅限 rime-ice 两份导出（已消费并移出工作区，git 历史 `6438887` 可查），只筛高价值词条。
- D-3：不保留置顶 / 隐藏 / 降频规则层。
- D-4：中文基础词库为项目内副本，构建与部署不依赖外部 rime-ice 路径。
- D-5：个人词库用 Rime 原生格式（`custom_phrase.txt` + `dict.yaml`），不引入 YAML → dict 构建层。
- D-6：多机同步主路径为 Git；Rime 原生同步仅作运行态备份与迁移输入。
- D-7：挂载 melt_eng 英文词库。
- D-8：已被 D-12 推翻（原命名 `huan_pinyin`）。
- D-9：Emoji 不进首版；数据来源定为 vendor rime-ice opencc 文件，挂载推迟。
- D-10：部署范围仅 `~/.local/share/fcitx5/rime`。
- D-11：部署方式为软链接切换；deploy 脚本遇真实目录一律停止。
- D-12：命名简化 `huan_pinyin` → `pinyin`、`char-lib/` → `cn_dicts/`。
- D-13：rime-ice 的 embedded 与 embedded_huan 合并为单一 `cn_dicts/embedded.dict.yaml`；mydict 原样迁移（阶段 2）。
- D-14：userdb 晋升标准——按（词、拼音）合并 c 值、门槛 c_total ≥ 3、排除已收录词与单字、人工剔除组句残留与错词、统一权重 100、带日期分区追加（阶段 3）。
- D-15：词库长期维护按 [docs/design/lexicon-sop.md](docs/design/lexicon-sop.md) 执行；晋升分析源自 rime-ice 归档导出扩展为现役 `pinyin.userdb` 导出。
- D-16：记录与清理规则见 [docs-rules.md](docs-rules.md)——工作区只保留当前事实与未决过程，历史由 git 承担。
- D-17：AI daemon 延迟模型为「按需触发 + 异步预取」——热路径零等待（filter 仅非阻塞收发 + 缓存查表），结果展示走专用触发键（有界等待在途结果 + 强制刷新）；依据 2026-07-08 socket 探针实测（unix RTT p50 ≈ 12µs，超时可封顶，缺席时 µs 级降级）。
- D-18：AI 候选工作负载 = LLM 生成式智能候补走 OpenAI 兼容 API（当日由重排式演进为生成式，用户验收反馈驱动；octagram 不覆盖诉求，不走该轨道）；模型默认 `gpt-5.4` + `reasoning_effort: low`（模型子项已被 D-22 推翻；初选 spark 因 token 烧量与方差同日调整），预取默认开（该子项已被 D-21 推翻），触发键 `Tab`；构成与参数见 architecture.md §2 与 services/candidate-daemon/README.md。
- D-19：性能红线修订为预算制——热路径 Lua ≤ 0.1ms/键，filters 仅 uniquifier + ai.suggest；推翻 D-17 前「热路径零 Lua」表述（该红线由 D-18 定义性触发修订）。
- D-20：AI 触发架构并发化 + 两拍触发契约（协议 v1.2，2026-07-09）——daemon 并发槽（默认 3）替代串行锁、auto 请求音节完整门控、commit 作废所有在队请求（去抖中 + 等槽的，含 explicit）；触发键 explicit 快车道跳过去抖；Tab 未命中亮 `⚡…` 段提示；自动预取 / 触发阈值分离 6 / 4；请求增 `explicit` / `prefix` 字段并修复选定首词后候补重复前缀的缺陷。（auto 门控 / 去抖 / 阈值分离 / explicit 字段等 auto 路径子项已被 D-21 推翻；并发槽 / 防重 / commit 作废 / 两拍契约保留现行。）动因与验证见 architecture.md §2。
- D-21：撤销自动预取，AI 候补纯触发式（协议 v1.3，2026-07-09）——预取结果无法自行弹出（librime 无异步刷新通道），正常打字节奏下产出几乎总在上屏后作废，只烧 token 不产出；daemon 移除 auto 路径（门控 / 去抖 / `debounce_ms` 废弃），所有请求直达并发槽；filter 只收包注入不预取；`ai_suggest` 开关撤销（不按 Tab 零上云）；协议 v1.3 移除 `explicit` 字段。动因与验证见 architecture.md §2。
- D-22：AI 候补改用 `gpt-5.6-sol` + `low` + Priority processing；系统提示词收敛为 99 字并保留嵌入式领域消歧。五类样例中 Sol / Terra 均 5/5，Sol 延迟中位数 2.784s、均值 3.198s，优于 Terra；Luna 4/5、中位数 5.012s，故选 Sol。完整口径见 architecture.md §2。

## 阶段与验证状态

- 阶段 0 / 1（骨架、最小可部署输入法）：2026-07-02 完成并验收（architecture.md §10）。
- 阶段 2 / 3（个人词库迁移、userdb 晋升 93 条）：2026-07-07 完成并验收（architecture.md §11）；验证方式为隔离 staging 构建（零 error）+ librime C API 按键探针（12/12 用例）+ Codex 独立交叉审核。
- AI 候补通路 M0 / M1（D-17/18/19 实现）：2026-07-08 完成并验收（architecture.md §12）；staging 构建零 E + 降级 / mock / 真 API 三档探针全过；真机 fcitx5 的 glue 链路已经用户实际输入证实，候补体验抽查随日常使用。
- AI 触发架构 v1.2（D-20）：2026-07-09 完成并验收——mock e2e 六项调度行为 + 客户端 payload / 重试单测 + staging 构建零 E；真机抽查（`⚡…` 提示重绘、两拍收割节奏）同日经用户实际输入确认正常。
- AI 候补纯触发式 v1.3（D-21）：2026-07-09 晚间完成——mock e2e（直达并发槽 / 同 key 防重 / commit 作废）+ glue payload 断言 + staging 构建零 E；真机体验抽查随日常使用。
- 词库维护进入长期运营态，流程见 [docs/design/lexicon-sop.md](docs/design/lexicon-sop.md)。

## 未决事项

- AI 候选通路 M2 收尾未做（不阻塞使用）：仅剩 socket activation 常驻优化——见 [docs/design/ai-daemon.md](docs/design/ai-daemon.md) §8。
- 测试期 API key 用后需作废轮换（曾在会话明文出现）。
- 本机已装未启用的 librime 插件（2026-07-07 探明，为后续扩展的前置事实）：`librime-plugin-octagram`（n-gram 语法模型，挂载尚缺 `.gram` 模型文件与 schema 配置）；`librime-plugin-lua`（动态链接系统 `liblua5.4`，`lua-socket 3.1.0-1` 可加载性已于 2026-07-08 实测确认，见上条）。
- Emoji、`ext` 扩展词库：挂载点与数据来源已定（architecture.md §8），未挂载。
