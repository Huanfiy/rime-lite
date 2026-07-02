# rime-lite 最小配置架构


| 项         | 内容                                                                                       |
| --------- | ---------------------------------------------------------------------------------------- |
| 创建日期      | 2026-07-02                                                                               |
| 状态        | 已拍板，作为首版实施依据                                                                             |
| 决策推导      | [2026-07-01 架构评审待确认事项](../2-exp/analysis/2026-07-01-architecture-open-questions.md)      |
| 原始计划      | `.agents/plans/2026-06-25-rime-lite-project-plan.md`（已移出工作区，git 历史 `d764656` 可查）         |
| vendor 来源 | `/home/huan/sync/fcitx5/share/rime`（现用 rime-ice 工程）                                      |
| 部署目标      | `/home/huan/.local/share/fcitx5/rime`                                                    |


## 1. 定位与范围

首版目标：一个可整目录部署、不依赖外部 rime-ice 工程路径、Git 全量管理的最小全拼输入方案。

**首版覆盖：**

- 全拼简体中文输入（字表 + 基础词库）。
- 英文输入（挂载 melt_eng 词库，支持中文方案内英文候选与独立英文方案）。
- 个人固定短语（`custom_phrase.txt`，Rime 原生格式）。
- 本机输入学习（Rime userdb，仅作运行态缓存）。
- 单命令部署到 fcitx5 Rime 用户目录。

**首版不覆盖：**

- Emoji（数据来源已确认，挂载推迟，见第 8 节）。
- 扩展词库 `ext`、腾讯词库等大词库。
- 置顶 / 隐藏 / 降频规则层（已确认永久移除）。
- Lua 脚本（首版零 Lua，热路径无脚本开销）。
- AI 候选 daemon（OQ-2 未决，仅保留挂载点）。
- 双拼、反查、日期、计算器等工具型扩展。
- fcitx5 以外的部署平台。

## 2. 决策记录

2026-07-01 评审已确认的结论（推导过程见 [2-exp 评审文档](../2-exp/analysis/2026-07-01-architecture-open-questions.md)）：


| 编号   | 决策                                                                       |
| ---- | ------------------------------------------------------------------------ |
| D-1  | 不自建 `events/*.jsonl`；userdb 仅作本机学习缓存，稳定词条走「导出 → 审核 → 晋升静态词库 → Git」        |
| D-2  | userdb 晋升分析源仅限 `sync/huan_rime/` 下两份导出文本，只筛选高价值词条，不全量导入                   |
| D-3  | 不保留置顶 / 隐藏机制（`pin_cand_filter`、`cold_word_drop` 及任何替代规则层）                 |
| D-4  | 基础词库采用项目内副本，集中放入 `char-lib/`，构建与部署不得依赖外部 rime-ice 路径                      |
| D-5  | 个人词库使用 Rime 原生格式（`custom_phrase.txt` + `dict.yaml`），不引入 YAML → dict 构建层   |
| D-6  | Git 同步工程源为主路径；Rime 原生同步仅作运行态备份与迁移输入（OQ-10）                                |


2026-07-02 拍板的新增决策：


| 编号   | 决策                                             | 说明                                                              |
| ---- | ---------------------------------------------- | --------------------------------------------------------------- |
| D-7  | 挂载 melt_eng 英文词库                               | 推翻 OQ-9 原倾向（仅固定英文技术词）。理由：日常英文输入量不可忽略，仅靠 `custom_phrase` 固定词条不可接受 |
| D-8  | 首版方案命名 `huan_pinyin`                           | 采用原计划 §12 建议，个人专属工程属性优先                                          |
| D-9  | Emoji 不进首版                                     | OQ-8 的数据来源结论（vendor rime-ice opencc 文件）保持有效，仅挂载时机推迟             |
| D-10 | 部署范围仅 `/home/huan/.local/share/fcitx5/rime`    | 确认 OQ-11 倾向                                                     |


未决事项：OQ-2（AI daemon 延迟模型与 Lua socket 可行性）不阻塞首版，前置动作为独立的 socket 能力探针，见第 8 节。

## 3. 仓库目录结构

```text
rime-lite/
├── docs/                        # 文档（ref / exp / sol 三段式）
├── rime/                        # 部署单元：整目录同步到 Rime 用户目录
│   ├── default.yaml             # 全局配置：方案列表、菜单、方案选单
│   ├── huan_pinyin.schema.yaml  # 主方案：全拼
│   ├── huan_pinyin.dict.yaml    # 主词库入口：仅 import_tables，不含词条
│   ├── melt_eng.schema.yaml     # 独立英文方案（vendor）
│   ├── melt_eng.dict.yaml       # 英文词库入口（vendor，裁剪）
│   ├── custom_phrase.txt        # 个人固定短语（Rime 原生 table 格式）
│   ├── char-lib/                # 中文基础词库项目内副本（D-4）
│   │   ├── 8105.dict.yaml       # 字表
│   │   └── base.dict.yaml       # 基础词库
│   └── en_dicts/
│       └── en.dict.yaml         # 英文主词库（vendor）
├── tools/
│   └── deploy                   # 部署脚本，行为约定见第 6 节
└── .gitignore
```

结构要点：

- **无构建层**。依据 D-5，`rime/` 目录内即 Rime 可直接读取的源文件，部署等于复制。原计划 §4 的 `src/ → build/ → deploy/` 三层结构随构建层一并取消；后续若引入生成型词库，再恢复分层。
- **`char-lib/` 与 `en_dicts/` 分置**。D-4 的 `char-lib/` 决策形成于英文词库尚在剥离范围时，仅约束中文基础词库；英文词库沿用 rime-ice 的 `en_dicts/` 路径约定，使 vendor 的 `melt_eng.dict.yaml` 中 `import_tables` 路径改动最小。
- **中文基础词库首版仅 `8105`（字表）+ `base`（基础词）**。`ext` 为可选扩展，挂载方式见第 8 节；`tencent` 不引入（沿用原计划 §12）。
- 词库子目录只用单层路径（`char-lib/8105`、`en_dicts/en`），与 rime-ice 的 `import_tables` 用法一致，不引入多层嵌套。

## 4. 模块设计

### 4.1 default.yaml

以 vendor 源 `default.yaml` 为基础裁剪，仅保留：

```yaml
schema_list:
  - schema: huan_pinyin
  - schema: melt_eng
menu:
  page_size: 5
```

另保留方案选单（switcher）快捷键与 ASCII 切换配置；移除双拼方案项、工具型 recognizer 模式等与首版无关的段落。

### 4.2 huan_pinyin.schema.yaml

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
  dictionary: huan_pinyin
  enable_user_dict: true     # 本机学习缓存，产出 userdb，不进 Git（D-1）

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

speller 仅保留标准全拼拼写规则（含 v → ü 处理），不引入模糊音与自动纠错。

### 4.3 词库层

- `huan_pinyin.dict.yaml`：仅作入口，`import_tables: [char-lib/8105, char-lib/base]`，自身不含词条。新增词库时只改此文件的 import 列表。
- `melt_eng.dict.yaml`：vendor 后裁剪，`import_tables` 仅保留 `en_dicts/en`，移除 `en_dicts/en_ext`。
- `melt_eng.schema.yaml`：vendor 独立英文方案，无 Lua 依赖，可经方案选单切换为纯英文输入。

### 4.4 custom_phrase.txt

Rime 原生 table 格式（`词条<Tab>编码<Tab>权重`），承载个人固定短语与英文技术词的定制写法（如 `GPIO`、`FreeRTOS` 的固定大小写）。初始内容从现用工程 `custom_phrase.txt` 人工筛选迁移，不整文件照搬。

## 5. vendor 规范

- 来源固定为 `/home/huan/sync/fcitx5/share/rime`（现用 rime-ice 工程本机版本）。
- vendor 对象：`char-lib/8105.dict.yaml`、`char-lib/base.dict.yaml`（源于 `cn_dicts/`）、`en_dicts/en.dict.yaml`、`melt_eng.schema.yaml`、`melt_eng.dict.yaml`。
- 每个 vendor 文件头部注释记录：来源文件路径、vendor 日期、是否有本地裁剪。
- vendor 后即为项目内独立副本，不追随上游更新；如需同步上游，人工 diff 后决定。
- 仓库内任何文件不得引用 `/home/huan/sync/fcitx5/share/rime` 路径（D-4 的强约束，作为首版验收项）。

## 6. 部署流程

`tools/deploy` 行为约定：

1. 将 `rime/` 目录内容复制到 `/home/huan/.local/share/fcitx5/rime`。
2. 保护清单——以下目标目录内的运行态对象一律不写入、不删除：`*.userdb/`、`sync/`、`build/`、`installation.yaml`、`user.yaml`。
3. 复制前打印将覆盖的文件清单。
4. 复制完成后提示手动触发 Rime 重新部署（fcitx5 的「重新部署」动作），脚本不代为执行。

首版无构建步骤，`tools/` 下仅此一个脚本；原计划 §4 的 `build`、`import-rime-userdb`、`compact-lexicon`、`smoke`、`bench` 均推迟到对应阶段再引入。

## 7. 输入学习与多机同步

- **本机学习**：主翻译器 `enable_user_dict: true`，学习结果落在目标目录的 userdb，属运行态，不进 Git（D-1）。
- **词条晋升**：定期从 Rime 同步目录导出 userdb 文本 → 人工筛选高价值词条 → 写入 `custom_phrase.txt`（固定短语类）→ Git 提交。分析源仅限 `sync/huan_rime/rime_ice.userdb.txt` 与 `sync/huan_rime/rime_ice_huan.userdb.txt` 两份现有导出（D-2）。首版为纯手工流程，导入工具推迟到阶段 3。
- **多机同步**：Git 同步 `rime/` 与 `tools/`，新机器初始化流程为 `git clone` + `tools/deploy`；各机 userdb 独立演化，不要求实时一致（D-6）。

## 8. 扩展挂载点（非首版）

| 扩展        | 挂载方式                                                                      | 前置条件                        |
| --------- | ------------------------------------------------------------------------- | --------------------------- |
| Emoji     | vendor `opencc/emoji.json` + `emoji.txt` 至 `rime/opencc/`，filters 增加 `simplifier@emoji` | 无（数据来源已确认，D-9）              |
| ext 扩展词库  | vendor `cn_dicts/ext.dict.yaml` 至 `char-lib/`，追加进 `import_tables`          | 基础词库候选覆盖不足时启用               |
| 个人领域词库    | 新增 `*.dict.yaml` 追加进 `import_tables`（D-5，Rime 原生格式）                        | 阶段 2                        |
| AI daemon | translators / filters 预留 lua 槽位；首版不落任何 Lua 文件                              | OQ-2 拍板 + Lua socket 能力探针通过 |

## 9. 与原计划的偏离

| 原计划                                    | 首版方案                     | 依据             |
| -------------------------------------- | ------------------------ | -------------- |
| §4 `src/ → build/ → deploy/` 三层结构       | `rime/` 单层，复制即部署         | D-5（无构建层）      |
| §5.2 剥离 melt_eng                        | 纳入首版                     | D-7（2026-07-02 拍板，推翻 OQ-9 倾向） |
| 阶段 1 目标含 Emoji                          | 推迟至扩展挂载点                 | D-9（2026-07-02 拍板） |
| §6.1 固定短语用 YAML 结构化源                    | `custom_phrase.txt` 原生格式 | D-5            |
| §3.3 `events/*.jsonl` 输入事件层             | 不建                       | D-1            |
| §4 `personal/lexicon/rules.yaml` 置顶降频规则 | 不建                       | D-3            |
| §4 tools 六件套                            | 仅 `tools/deploy`         | 无构建层与事件层，其余无对象 |

## 10. 首版完成判定

- [ ] 部署后 `nihao`、`shijie` 输出预期中文候选（验证 `char-lib/8105` + `base` 生效）。
- [ ] 输入 `hello` 出现英文候选（验证 melt_eng 挂载生效）。
- [ ] `custom_phrase.txt` 中的词条（如 `gpio` → `GPIO`）出现且位于首位（验证 `initial_quality: 99` 排序）。
- [ ] 方案选单可在 `huan_pinyin` 与 `melt_eng` 间切换。
- [ ] 全新环境 `git clone` + `tools/deploy` 后输入可用，全程未读取 `/home/huan/sync/fcitx5/share/rime`（D-4 验收）。
- [ ] 重复执行 `tools/deploy` 不破坏目标目录内 userdb 与 `sync/`。
