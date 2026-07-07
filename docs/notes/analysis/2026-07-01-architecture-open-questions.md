# rime-lite 架构评审:待确认事项


| 项    | 内容                                                                                                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------- |
| 创建日期 | 2026-07-01                                                                                                          |
| 评审对象 | `[.agents/plans/2026-06-25-rime-lite-project-plan.md](../../../.agents/plans/2026-06-25-rime-lite-project-plan.md)` |
| 参考项目 | `/home/huan/sync/fcitx5/share/rime`(现用 rime-ice 工程)                                                                 |
| 状态   | 已确认决策保留在"确认结论";已废弃项不再进入待确认列表;其余事项进入阶段 1 前需拍板;拍板后把结论搬入 `[../../design](../../design)`                                  |
| 结论摘要 | 核心三原则(源/产物分离、热路径最小化、插件化)方向正确;输入学习采用"静态源进 Git、本机即时学习用 Rime userdb、定期导出后审核晋升"架构;主要剩余风险在"AI daemon"抽象                  |


本文件记录评审中浮现的待确认决策,属探索层(过程性、可推翻)。每项给出问题、依据、选项、当前倾向、影响范围。已整合原计划第 11 节的 5 个待确认问题,去重后统一编号 `OQ-n`,便于后续讨论引用。

## 确认结论

- 输入学习:不自建 `events/*.jsonl`;Rime userdb 仅作为本机运行态学习缓存;稳定词条通过"导出 userdb → 审核 → 晋升静态词库 → Git 同步"沉淀。
- userdb 晋升:初步仅使用 `sync/huan_rime/rime_ice.userdb.txt` 与 `sync/huan_rime/rime_ice_huan.userdb.txt` 两份导出作为分析源;不全量导入,只筛选高价值词条晋升。
- 置顶 / 隐藏:去除专用机制;不保留 `pin_cand_filter`、`cold_word_drop` 或替代性的 `pin/hide` 规则层。
- 基础词库:采用项目内副本,集中放入 `char-lib/`;构建过程不得依赖外部 rime-ice 工程路径。
- 个人词库:阶段 1/2 使用 Rime 原生格式(`custom_phrase.txt` + `dict.yaml`);暂不引入 YAML → dict 构建层。
- 多机同步:Git 同步工程源;Rime 原生同步仅作运行态备份与迁移输入。

2026-07-02 拍板新增(结论已落档 [../../design/architecture.md](../../design/architecture.md)):

- 英文输入:挂载 `melt_eng` 与 `en_dicts/en`,推翻 OQ-9 原倾向;理由:日常英文输入量不可忽略,仅靠固定词条不可接受。
- Emoji:数据来源维持 OQ-8 结论(vendor rime-ice opencc);首版最小配置暂不挂载。
- 首版方案命名:`huan_pinyin`(采用原计划 §12 建议)。
- OQ-10、OQ-11:按原倾向确认。

## 优先级说明

- **P0 — 需改设计**:影响目录结构与阶段 1/2 工作量,或建立在未验证假设上,必须先定。
- **P1 — 需定细节**:方向不变,但落地方式要明确。
- **P2 — 倾向已明确 / 低风险**:多为沿用现状,确认即可。

## 速览表


| ID    | 优先级 | 议题                         | 当前倾向                                    |
| ----- | --- | -------------------------- | --------------------------------------- |
| OQ-2  | P0  | AI daemon 延迟模型与 socket 可行性 | 改按需触发 + 异步预取;提前验证 socket                |
| OQ-8  | P2  | Emoji 数据来源                 | 已拍板(2026-07-02):vendor rime-ice opencc;首版暂不挂载 Emoji |
| OQ-9  | P2  | 首版英文输入范围                   | 已拍板(2026-07-02):挂 melt_eng,推翻原倾向          |
| OQ-10 | P2  | 多机同步主路径                    | 已拍板(2026-07-02):Git 主路径;Rime sync 仅作运行态备份与迁移输入 |
| OQ-11 | P2  | 部署目标范围                     | 已拍板(2026-07-02):仅 `fcitx5/rime`             |


---

## P0 — 需改设计

### OQ-2 AI daemon 延迟模型与 Lua socket 可行性

**问题**:8.1 节读起来是"每次按键"同步调用本地服务(20-50 ms 超时),该模型在热路径上站不住,且底层能力未验证。

**依据**:

- librime-lua 的 filter/translator 调用是同步的。daemon "变慢但没死"时,30 ms 超时会在每次按键触发 → 每键卡顿,比 daemon 直接挂掉更糟。
- 标准 librime-lua 沙箱不自带 luasocket。Lua 能否开 Unix socket / localhost HTTP,取决于本机 fcitx5-rime 构建是否注入了对应库——这是阶段 4 的硬前置,需提前验证,否则整个 daemon 方案落不了地。

**选项**:
1.(倾向)延迟模型改为按需触发(专用功能键 / 组合长度 ≥ N 且空闲 > X ms)+ 异步预取缓存(filter 只读上一键算好的重排结果)。
2. 保留同步调用,但仅在极窄触发条件下,超时压到 ≤ 15 ms。
3. 维持"每键同步"(不推荐)。

**前置动作**:阶段 4 前先做 socket 能力探针,确认 Lua 侧可发起本地 IPC。

**影响**:决定 8 节整体接口形态与 `services/candidate-daemon/protocol.md` 的设计。

**状态**:待确认(socket 可行性为阻断项)。

## P2 — 倾向已明确 / 低风险

### OQ-8 Emoji 数据来源

**倾向**:直接 vendor rime-ice 的 opencc emoji 文件,不改成"结构化源再生成",无收益。

**状态**:已拍板(2026-07-02)。数据来源按倾向确认;首版最小配置暂不挂载 Emoji,列为扩展挂载点,见 [design/architecture.md](../../design/architecture.md) D-9。

### OQ-9 首版英文输入范围

**倾向**:仅保留固定英文技术词(走 `fixed_phrase`),不挂 `melt_eng` 大型英文词库与 `cn_en` 混输(与计划 5.2 一致)。需确认日常英文输入量是否可接受。

**状态**:已拍板(2026-07-02),推翻倾向——挂载 `melt_eng` 与 `en_dicts/en`(`cn_en` 混输词库维持不引入)。理由:日常英文输入量不可忽略,仅靠固定词条不可接受。见 [design/architecture.md](../../design/architecture.md) D-7。

### OQ-10 多机同步主路径

**倾向**:Git 为主(同步源数据与工具),Rime 原生同步仅作运行态备份与迁移输入,不作为工程主同步路径。跨机一致性来自静态词库、`custom_phrase.txt` 与构建规则;各设备的即时学习结果保留在本机 userdb,不要求实时一致。稳定词条通过"导出 userdb → 审核 → 晋升静态词库 → Git 同步"进入跨机一致范围。

**状态**:已拍板(2026-07-02),按倾向确认。

### OQ-11 部署目标范围

**倾向**:首版仅覆盖 `/home/huan/.local/share/fcitx5/rime`,暂不考虑其他平台。

**状态**:已拍板(2026-07-02),按倾向确认。

---

## 后续动作

1. 逐项拍板未确认事项(P0 优先)。
2. OQ-2 的 socket 可行性探针可独立于其他决策先行。
3. 拍板结论搬入 `[../../design](../../design)`,本文件保留推导过程。(2026-07-02 已完成:[architecture.md](../../design/architecture.md),覆盖除 OQ-2 外全部事项)
4. 依结论回改 `[.agents/plans/2026-06-25-rime-lite-project-plan.md](../../../.agents/plans/2026-06-25-rime-lite-project-plan.md)`(尤其目录结构与阶段划分)。

