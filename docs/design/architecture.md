# rime-lite 最小配置架构


| 项         | 内容                                                                                       |
| --------- | ---------------------------------------------------------------------------------------- |
| 创建日期      | 2026-07-02                                                                               |
| 状态        | 已拍板，作为首版实施依据                                                                             |
| 决策推导      | [2026-07-01 架构评审待确认事项](../notes/analysis/2026-07-01-architecture-open-questions.md)      |
| 原始计划      | `.agents/plans/2026-06-25-rime-lite-project-plan.md`（已移出工作区，git 历史 `d764656` 可查）         |
| vendor 来源 | rime-ice 工程，现位于 `/home/huan/sync/rime-ice`（vendor 当日位于 `/home/huan/sync/fcitx5/share/rime`，2026-07-02 迁出） |
| 部署目标      | `/home/huan/.local/share/fcitx5/rime`                                                    |


## 1. 定位与范围

首版目标：一个可整目录部署、不依赖外部 rime-ice 工程路径、Git 全量管理的最小全拼输入方案。

**首版覆盖：**

- 全拼简体中文输入（字表 + 基础词库）。
- 英文输入（挂载 melt_eng 词库，中文方案内出英文候选；独立英文方案已于 2026-07-02 移出方案列表，git `e4aab2b`）。
- 个人固定短语（`custom_phrase.txt`，Rime 原生格式）。
- 本机输入学习（Rime userdb，仅作运行态缓存）。
- 单命令激活：fcitx5 的 Rime 用户目录软链接指向本工程 `rime/`，可与 rime-ice 双向切换。

**首版不覆盖：**

- Emoji（数据来源已确认，挂载推迟，见第 8 节）。
- 扩展词库 `ext`、腾讯词库等大词库。
- 置顶 / 隐藏 / 降频规则层（已确认永久移除）。
- Lua 脚本（首版零 Lua，热路径无脚本开销）。
- AI 候选 daemon（OQ-2 未决，仅保留挂载点）。
- 双拼、反查、日期、计算器等工具型扩展。
- fcitx5 以外的部署平台。

## 2. 决策记录

2026-07-01 评审已确认的结论（推导过程见 [notes 评审文档](../notes/analysis/2026-07-01-architecture-open-questions.md)）：


| 编号   | 决策                                                                       |
| ---- | ------------------------------------------------------------------------ |
| D-1  | 不自建 `events/*.jsonl`；userdb 仅作本机学习缓存，稳定词条走「导出 → 审核 → 晋升静态词库 → Git」        |
| D-2  | userdb 晋升分析源仅限 `sync/huan_rime/` 下两份导出文本（阶段 3 消费后已移出工作区，git 历史 `6438887` 可查），只筛选高价值词条，不全量导入 |
| D-3  | 不保留置顶 / 隐藏机制（`pin_cand_filter`、`cold_word_drop` 及任何替代规则层）                 |
| D-4  | 基础词库采用项目内副本，集中放入 `char-lib/`（后经 D-12 更名 `cn_dicts/`），构建与部署不得依赖外部 rime-ice 路径 |
| D-5  | 个人词库使用 Rime 原生格式（`custom_phrase.txt` + `dict.yaml`），不引入 YAML → dict 构建层   |
| D-6  | Git 同步工程源为主路径；Rime 原生同步仅作运行态备份与迁移输入（OQ-10）                                |


2026-07-02 拍板的新增决策：


| 编号   | 决策                                             | 说明                                                              |
| ---- | ---------------------------------------------- | --------------------------------------------------------------- |
| D-7  | 挂载 melt_eng 英文词库                               | 推翻 OQ-9 原倾向（仅固定英文技术词）。理由：日常英文输入量不可忽略，仅靠 `custom_phrase` 固定词条不可接受 |
| D-8  | 首版方案命名 `huan_pinyin`                           | 采用原计划 §12 建议，个人专属工程属性优先（已被 D-12 推翻）                              |
| D-9  | Emoji 不进首版                                     | OQ-8 的数据来源结论（vendor rime-ice opencc 文件）保持有效，仅挂载时机推迟             |
| D-10 | 部署范围仅 `/home/huan/.local/share/fcitx5/rime`    | 确认 OQ-11 倾向                                                     |
| D-11 | 部署方式为软链接切换                                   | fcitx5 用户目录 `rime` 为软链接，指向当前激活工程的配置目录；rime-lite 与 rime-ice 为平级工程，切换 = 重指链接，互不修改对方文件 |
| D-12 | 命名简化：`huan_pinyin` → `pinyin`，`char-lib/` → `cn_dicts/` | 推翻 D-8：schema_id、词库入口、显示名统一为 `pinyin`，去除个人前缀；`cn_dicts/` 回归 rime-ice 目录命名约定。userdb 学习数据经 `rime_dict_manager` 导出 / 导入无损迁移（168 条） |


2026-07-07 拍板的新增决策：


| 编号   | 决策                | 说明                                                              |
| ---- | ----------------- | --------------------------------------------------------------- |
| D-13 | 个人领域词库合并挂载（阶段 2） | rime-ice 的 `embedded` 与 `embedded_huan` 合并为单一 `cn_dicts/embedded.dict.yaml`（同词同音去重取高权重，552 条）；`mydict.dict.yaml` 原样迁移（3 条）；均经 `pinyin.dict.yaml` 的 `import_tables` 挂载 |
| D-14 | userdb 晋升标准（阶段 3） | 分析源为 rime-ice 两份 userdb 导出（D-2，git 历史 `6438887`）；按（词、拼音）合并两份 c 值，门槛 c_total ≥ 3；排除 c ≤ 0、单字、已收录词（base / 8105 / embedded / mydict / custom_phrase / A–Z 词条）；人工剔除组句残留与错词；晋升词条以 `# ========== userdb 晋升 (日期) ==========` 分区追加至目标词库，统一权重 100 |
| D-15 | 词库长期维护流程 SOP 化 | 日常加词与周期性晋升按 [lexicon-sop.md](lexicon-sop.md) 执行；晋升分析源自 rime-ice 归档导出扩展为现役 `pinyin.userdb` 导出（Rime 原生同步产物为主路径）；候选分析固化为 `tools/userdb-candidates`（机械筛选，D-14 规则），人工审定环节不可省略 |
| D-16 | 记录与清理规则落档 | 信息治理规则见根目录 [docs-rules.md](../../docs-rules.md)：工作区只保留当前事实与未决过程，历史由 git 承担；记录门槛、清理触发点 / 判据 / 方式及既有先例见该文件 |


未决事项：OQ-2（AI daemon 延迟模型与 Lua socket 可行性）不阻塞首版，前置动作为独立的 socket 能力探针，见第 8 节。

## 3. 仓库目录结构

```text
rime-lite/
├── docs/                        # 文档（ref / exp / sol 三段式）
├── rime/                        # 部署单元：整目录同步到 Rime 用户目录
│   ├── default.yaml             # 全局配置：方案列表、菜单、方案选单
│   ├── pinyin.schema.yaml       # 主方案：全拼
│   ├── pinyin.dict.yaml         # 主词库入口：仅 import_tables，不含词条
│   ├── melt_eng.schema.yaml     # 独立英文方案（vendor）
│   ├── melt_eng.dict.yaml       # 英文词库入口（vendor，裁剪）
│   ├── custom_phrase.txt        # 个人固定短语（Rime 原生 table 格式）
│   ├── cn_dicts/                # 中文词库项目内副本（D-4，D-12 更名）
│   │   ├── 8105.dict.yaml       # 字表
│   │   ├── base.dict.yaml       # 基础词库
│   │   ├── embedded.dict.yaml   # 个人领域词库（D-13，2026-07-07 挂载）
│   │   └── mydict.dict.yaml     # 个人自定义词库（D-13，2026-07-07 挂载）
│   └── en_dicts/
│       └── en.dict.yaml         # 英文主词库（vendor）
├── tools/
│   ├── deploy                   # 部署脚本，行为约定见第 6 节
│   └── userdb-candidates        # userdb 晋升候选分析（D-15，用法见 lexicon-sop.md §3.2）
└── .gitignore
```

结构要点：

- **无构建层**。依据 D-5，`rime/` 目录内即 Rime 可直接读取的源文件，部署等于复制。原计划 §4 的 `src/ → build/ → deploy/` 三层结构随构建层一并取消；后续若引入生成型词库，再恢复分层。
- **`cn_dicts/` 与 `en_dicts/` 分置**。D-4 原命名 `char-lib/`（形成于英文词库尚在剥离范围时，仅约束中文基础词库），D-12 更名 `cn_dicts/` 后与 `en_dicts/` 一并回归 rime-ice 的目录命名约定；vendor 的 `melt_eng.dict.yaml` 中 `import_tables` 路径始终无需改动。
- **中文基础词库首版仅 `8105`（字表）+ `base`（基础词）**。`ext` 为可选扩展，挂载方式见第 8 节；`tencent` 不引入（沿用原计划 §12）。
- 词库子目录只用单层路径（`cn_dicts/8105`、`en_dicts/en`），与 rime-ice 的 `import_tables` 用法一致，不引入多层嵌套。
- **`rime/` 同时是激活后的运行目录**（D-11）。Rime 运行态（`build/`、`*.userdb/`、`sync/`、`installation.yaml`、`user.yaml`）写入 `rime/` 内，由 `.gitignore` 隔离，不进 Git。

## 4. 模块设计

### 4.1 default.yaml

以 vendor 源 `default.yaml` 为基础裁剪，仅保留：

```yaml
schema_list:
  - schema: pinyin        # melt_eng 仅作词库挂载，不作独立方案（2026-07-02 调整，git e4aab2b）
menu:
  page_size: 5
```

另保留：方案选单（switcher）、ASCII 切换（ascii_composer）、标点映射（punctuator，供方案以 `import_preset: default` 引用）、通用 recognizer patterns（email / url / underscore）、基础 key_binder（光标移动、`-` / `=` 翻页、中英标点切换）。

移除：双拼方案项、简繁 / Emoji / Lua 相关快捷键，以及在本机 librime 1.10.0（fcitx5-rime 5.1.4）上无效的段落——navigator（需 librime >= 1.16.0）、`punctuator/digit_separators`（需 librime >= 1.13.0）。

### 4.2 pinyin.schema.yaml

engine 定案（首版零 Lua、零 OpenCC filter）：

```yaml
engine:
  processors:
    - ascii_composer
    - recognizer
    - key_binder
    - speller
    - punctuator
    - selector
    - navigator
    - express_editor
  segmentors:
    - ascii_segmentor
    - matcher            # 响应 recognizer 的 patterns（email、url 等）
    - abc_segmentor
    - punct_segmentor
    - fallback_segmentor
  translators:
    - punct_translator
    - script_translator
    - table_translator@custom_phrase
    - table_translator@melt_eng
  filters:
    - uniquifier
```

关键配置块（字段值以 vendor 源为基准，已核对）：

```yaml
translator:                  # 主翻译器：全拼
  dictionary: pinyin
  enable_user_dict: true     # 本机学习缓存，产出 userdb，不进 Git（D-1）
  initial_quality: 1.2       # 拼音权重高于 melt_eng

custom_phrase:               # 个人固定短语
  dictionary: ""
  user_dict: custom_phrase   # 读取 custom_phrase.txt
  db_class: stabledb
  enable_completion: false
  enable_sentence: false
  initial_quality: 99        # 高于拼音与 melt_eng，固定短语排序在前

melt_eng:                    # 英文词库挂载（D-7）
  dictionary: melt_eng
  enable_sentence: false
  enable_user_dict: false
  initial_quality: 1.1       # 低于中文候选，英文词不抢占首选
  comment_format:
    - xform/.*//
```

speller 保留标准全拼拼写规则（含 v / ü 转换）与超级简拼（abbrev 及配套 erase 规则，沿用 rime-ice），不引入模糊音与自动纠错。

### 4.3 词库层

- `pinyin.dict.yaml`：入口文件，`import_tables: [cn_dicts/8105, cn_dicts/base, cn_dicts/embedded, cn_dicts/mydict]`（后两项为阶段 2 挂载，D-13）；除迁移自现用工程的 26 个大写字母词条（Shift + 字母输入、大写字母参与造句）外不含词条。新增词库时只改此文件的 import 列表。
- `melt_eng.dict.yaml`：vendor 后裁剪，`import_tables` 仅保留 `en_dicts/en`，移除 `en_dicts/en_ext`。
- `melt_eng.schema.yaml`：vendor 英文方案文件，无 Lua 依赖；2026-07-02 起移出 `schema_list`（git `e4aab2b`），仅保留文件，melt_eng 词库经主方案 `table_translator@melt_eng` 挂载。

### 4.4 custom_phrase.txt

Rime 原生 table 格式（`词条<Tab>编码<Tab>权重`），承载个人固定短语与英文技术词的定制写法（如 `GPIO`、`FreeRTOS` 的固定大小写）。初始内容从现用工程 `custom_phrase.txt` 人工筛选迁移，不整文件照搬。

## 5. vendor 规范

- 来源固定为 rime-ice 工程本机版本（2026-07-02 起位于 `/home/huan/sync/rime-ice`，远端 github:Huanfiy/rime-ice；vendor 当日位于 `/home/huan/sync/fcitx5/share/rime`，文件头注释保留历史路径）。
- vendor 对象：`cn_dicts/8105.dict.yaml`、`cn_dicts/base.dict.yaml`、`en_dicts/en.dict.yaml`、`melt_eng.schema.yaml`、`melt_eng.dict.yaml`（词库目录名与 rime-ice 一致，D-12）。
- 每个 vendor 文件头部注释记录：来源文件路径、vendor 日期、是否有本地裁剪。
- vendor 时去除文件头 UTF-8 BOM：在文件前部插入注释后，BOM 会落到 YAML 流中间导致解析失败（现用工程仅 `melt_eng.schema.yaml` 带 BOM，2026-07-02 实测）。
- vendor 后即为项目内独立副本，不追随上游更新；如需同步上游，人工 diff 后决定。
- 仓库内任何文件不得引用 rime-ice 工程路径（现 `/home/huan/sync/rime-ice`；D-4 的强约束，作为首版验收项）。

## 6. 部署流程

部署采用软链接切换（D-11）：`~/.local/share/fcitx5/rime` 是指向当前激活工程配置目录的软链接。rime-lite 与 rime-ice 为平级工程，切换输入法工程 = 重指该链接，零复制，互不修改对方文件。

`tools/deploy` 行为约定：

1. `tools/deploy` 将链接指向本工程 `rime/`；`tools/deploy --to <dir>` 指向其他工程（切回 rime-ice：`--to /home/huan/sync/rime-ice`）；`--status` 查看当前激活工程；`--yes` 跳过确认。
2. 只创建 / 重指软链接；遇到真实目录一律停止，不覆盖、不删除。
3. `~/.local/share/fcitx5` 的最终形态（2026-07-02 演化完成）：真实目录；`addon`、`inputmethod`、`pinyin`、`table` 为本机真实目录；`themes` 软链接指向 `/home/huan/sync/pc_cfg/fcitx5/themes`（版本管理归 pc_cfg）；仅 `rime` 为工程切换软链接。原 `/home/huan/sync/fcitx5` 工程已于同日退役删除，历史保留在备份远端 `/mnt/backup/fcitx5`。
4. 切换后需重启 fcitx5（`fcitx5 -rd` 或注销重登）生效，脚本不代为执行。

无构建步骤；`tools/` 下现有 `deploy` 与 `userdb-candidates`（2026-07-07 随 D-15 引入）两个脚本，原计划 §4 的其余工具（`build`、`compact-lexicon`、`smoke`、`bench`）无对象，不引入。

## 7. 输入学习与多机同步

- **本机学习**：主翻译器 `enable_user_dict: true`，学习结果落在目标目录的 userdb，属运行态，不进 Git（D-1）。
- **词条晋升**：定期从 Rime 同步目录导出 userdb 文本 → 人工筛选高价值词条 → 写入 `custom_phrase.txt`（固定短语类）或目标词库（领域词 / 个人词）→ Git 提交。分析源仅限 `sync/huan_rime/rime_ice.userdb.txt` 与 `sync/huan_rime/rime_ice_huan.userdb.txt` 两份导出（D-2；rime-ice 退役前的最终导出已消费并移出工作区，git 历史 `6438887` 可查，工程本体在 `/home/huan/sync/rime-ice`）。首轮晋升已于 2026-07-07 按 D-14 完成：合并 10229 条 → 候选 143 条 → 晋升 93 条（embedded 50 / mydict 43，custom_phrase 无新增）。后续晋升按 [lexicon-sop.md](lexicon-sop.md) 执行（D-15）：分析源为现役 `pinyin.userdb` 的同步导出，候选分析用 `tools/userdb-candidates`。
- **多机同步**：Git 同步 `rime/` 与 `tools/`，新机器初始化流程为 `git clone` + `tools/deploy`；各机 userdb 独立演化，不要求实时一致（D-6）。

## 8. 扩展挂载点（非首版）

| 扩展        | 挂载方式                                                                      | 前置条件                        |
| --------- | ------------------------------------------------------------------------- | --------------------------- |
| Emoji     | vendor `opencc/emoji.json` + `emoji.txt` 至 `rime/opencc/`，filters 增加 `simplifier@emoji` | 无（数据来源已确认，D-9）              |
| ext 扩展词库  | vendor `cn_dicts/ext.dict.yaml` 至 `cn_dicts/`，追加进 `import_tables`          | 基础词库候选覆盖不足时启用               |
| 个人领域词库    | 新增 `*.dict.yaml` 追加进 `import_tables`（D-5，Rime 原生格式）                        | 已挂载（2026-07-07，D-13）      |
| AI daemon | translators / filters 预留 lua 槽位；首版不落任何 Lua 文件                              | OQ-2 拍板 + Lua socket 能力探针通过 |

## 9. 与原计划的偏离

本节已清理（2026-07-07）：对照对象「原计划」已移出工作区（git 历史 `d764656`），逐项偏离表失去参照价值；各偏离项的现行结论均由 §2 决策记录覆盖。历史内容见 git 提交 `b6a49e4` 之前的版本。

## 10. 首版完成判定

2026-07-02 已完成两轮验证：隔离 staging 目录（`rime_deployer --build` + librime 1.10.0 C API 按键探针），以及软链接切换后的真实激活路径（探针经 `~/.local/share/fcitx5/rime` 复验，双向切换复核）。fcitx5 前端交互（F4 方案选单）待重启 fcitx5 后确认。

- [x] 部署后 `nihao`、`shijie` 输出预期中文候选（实测首位：你好、世界，验证 `cn_dicts/8105` + `base` 生效；实测时目录名为 `char-lib/`，D-12 更名不影响结论）。
- [x] 输入 `hello` 出现英文候选且居首（验证 melt_eng 挂载生效）。
- [x] `custom_phrase.txt` 词条位于首位（实测 `gpio` → `GPIO`、`freertos` → `FreeRTOS`、`zkb` → `占空比`，验证 `initial_quality: 99` 排序）。
- [x] 可切换至 `melt_eng` 独立方案（API 级验证；后经 2026-07-02 调整移出 `schema_list`，不再作独立方案，git `e4aab2b`）。
- [x] 干净目录仅凭仓库文件 + `/usr/share/rime-data` 完成构建与输入（D-4 验收）。
- [x] `tools/deploy` 幂等且可双向切换（rime-lite ↔ rime-ice），全程不修改两个工程的文件与运行态。

## 11. 阶段 2/3 完成记录

2026-07-07 完成。验证方式：隔离 staging 构建（`rime_deployer --build` + librime 1.10.0 C API 按键探针，12/12 用例通过），另经 Codex 独立交叉审核（词库合并与晋升清单逐条比对零差异）。

- [x] 阶段 2（D-13）：`embedded.dict.yaml`（合并 488 + 74 条，去重 10 条冲突取高权重，552 条）与 `mydict.dict.yaml`（3 条）挂载生效；实测 `qianrushixitong` → 嵌入式系统、`zhankongbi` → 占空比、`shenfenyanzheng` → 身份验证 均居首位。
- [x] 阶段 3（D-14）：晋升 93 条（embedded 50 / mydict 43；候选 143 条中人工剔除组句残留 47 条、错词 3 条）；实测 `touchuan` → 透传、`luodang` → 落档、`furuikun` → 富芮坤 等均进前 5。
- [x] 回归不受影响：`nihao`、`hello`、`gpio`（custom_phrase）候选与首版一致；构建零 error；探针全程零写入仓库与 `~/.local/share/fcitx5/rime`。
- [x] D-4 复核：`rime/` 内无对 rime-ice 工程的运行时路径依赖（仅头部注释记录来源）。
- 已知偏差（审核发现，判定保留）：rime-ice 既有缩写码词条（如 `ARM<Tab>arm`）拼音字段为整词编码而非标准音节，属来源设计（输入 `arm` 出 `ARM` 的机制），不影响构建；mydict 的「身份验证」与 base 同词同音重复，运行时由 uniquifier 消重，按原样迁移保留。
