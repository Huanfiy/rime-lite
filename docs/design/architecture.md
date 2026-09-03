# rime-lite 最小配置架构

| 项 | 内容 |
| --- | --- |
| 状态 | 现行 |
| 部署目标 | `~/.local/share/fcitx5/rime`（D-10 / D-11） |

## 1. 定位与范围

可整目录部署、不依赖外部 rime-ice 运行时路径、Git 全量管理的最小全拼输入方案（仅 fcitx5）。

**覆盖：**

- 全拼简体：字表 `8105` + `base` + `embedded` + `mydict`
- 英文：melt_eng 挂载于中文方案，不作独立方案
- 个人固定短语（`custom_phrase.txt`）
- 本机 userdb 学习；稳定词条按 [lexicon-sop.md](lexicon-sop.md) 晋升
- 左 Shift 单击切 ASCII、快速双击切中（D-27）
- AI 智能候补，纯触发式（D-21）；结构见 [ai-daemon.md](ai-daemon.md)
- 软链接切换激活工程（D-11）

**不覆盖：** Emoji、`ext` / 腾讯词库、置顶 / 隐藏 / 降频规则层、双拼 / 反查 / 日期 / 计算器、fcitx5 以外平台。语音输入待实施，见 [voice-daemon.md](../plan/voice-daemon.md)。

## 2. 决策记录

被推翻的行保留编号，只记结论与指向。细则见对应 design / 组件 README，此处不复述。

| 编号 | 决策 |
| --- | --- |
| D-1 | 不自建 `events/*.jsonl`；userdb 仅本机学习缓存；稳定词条走导出 → 审核 → 晋升静态词库 → Git |
| D-2 | 只筛选高价值词条，不全量导入 userdb |
| D-3 | 不保留置顶 / 隐藏 / 降频规则层 |
| D-4 | 基础词库为项目内副本；构建与部署不得依赖外部 rime-ice 路径（目录名经 D-12 定为 `cn_dicts/`） |
| D-5 | 个人词库用 Rime 原生格式（`custom_phrase.txt` + `dict.yaml`），无 YAML → dict 构建层 |
| D-6 | Git 同步工程源为主路径；Rime 原生同步仅作运行态备份与迁移输入 |
| D-7 | 挂载 melt_eng 英文词库（中文方案内出英文候选） |
| D-8 | 方案命名 `huan_pinyin`。已被 D-12 推翻 |
| D-9 | Emoji 不进当前方案（数据来源已确认，挂载推迟） |
| D-10 | 部署范围仅 `~/.local/share/fcitx5/rime` |
| D-11 | 部署方式为软链接切换；遇真实目录停止，不覆盖、不删除；平级工程互不修改 |
| D-12 | schema / 词库入口 / 显示名统一 `pinyin`；`char-lib/` → `cn_dicts/` |
| D-13 | 个人领域词库为 `cn_dicts/embedded.dict.yaml`，另挂 `mydict.dict.yaml`，均经 `pinyin.dict.yaml` 的 `import_tables` |
| D-14 | userdb 晋升 = 机械筛选 + 人工审定；筛选规则单点在 `tools/userdb-candidates`，流程见 [lexicon-sop.md](lexicon-sop.md) |
| D-15 | 词库长期维护按 lexicon-sop 执行；分析源为现役 `pinyin.userdb` 导出；候选分析用 `tools/userdb-candidates`，人工审定不可省略 |
| D-16 | 记录与清理规则见根目录 [docs-rules.md](../../docs-rules.md) |
| D-17 | AI 延迟模型：热路径任何情况下不等待 daemon；结果展示以触发键为主入口。预取路径已被 D-21 撤销，触发键契约仍现行 |
| D-18 | AI 工作负载 = LLM 生成式智能候补（OpenAI 兼容 API）：≤3 条注入候选栏首位（⚡），本地候选跟随，uniquifier 消重。结构见 [ai-daemon.md](ai-daemon.md)。自动预取与 `ai_suggest` 开关已被 D-21 推翻 |
| D-19 | 热路径 Lua 预算 ≤ 0.1ms/键，且必须非阻塞；filters 仅 `uniquifier` + `ai.suggest`；零 OpenCC filter。`ascii_shift` 热路径仅 keycode 分支 |
| D-20 | daemon 并发槽（`max_concurrency` 默认 3）+ 同 key 在途防重 + commit 作废在队请求；两拍触发契约（未命中亮 `⚡…`）。auto 路径已被 D-21 推翻 |
| D-21 | 撤销自动预取，AI 候补纯触发式（协议 v1.3）：不按 Tab 零上云，无长度门槛。并发槽 / 防重 / commit 作废 / 两拍契约保留 |
| D-22 | 模型与推理参数走 daemon 配置（不入库）。提示词长度上限已被 D-23 推翻 |
| D-23 | 系统提示词上限 200 字；首项始终为转写；识别到表情意图时第 2、3 项仅输出匹配语义的 emoji / 颜文字，否则维持短延伸 |
| D-24 | 中英切换走 Lua processor，`ascii_composer` 的 `Shift_*` / `Caps_Lock` 置 noop。键位方案已被 D-25 → D-27 逐次推翻，Lua 路径与 noop 仍现行 |
| D-25 | Caps 点按即中。已被 D-26 推翻 |
| D-26 | 左 Shift 点按翻转中英。已被 D-27 推翻 |
| D-27 | 左 Shift 单击切 ASCII、快速双击切中文；右 Shift / Caps 不参与。时序参数与打断规则以 `rime/lua/ascii_shift.lua` 为准 |

未决事项：无阻塞项。语音见 [voice-daemon.md](../plan/voice-daemon.md)；AI M2 见 [ai-daemon.md](ai-daemon.md) §8。运行参数走 daemon 配置，不动仓库。

## 3. 仓库结构要点

目录树见 [README.md](../../README.md)。与部署相关的约束：

- **无构建层**（D-5）：`rime/` 内即 librime 可直接读取的源文件。
- **`rime/` 同时是激活后的运行目录**（D-11）：运行态由 `.gitignore` 隔离。
- 中文基础词库当前仅 `8105` + `base`；`ext` / `tencent` 不引入。词库子目录只用单层路径。

## 4. 模块设计

现行字段以对应文件为准，此处只记分层理由。

### 4.1 default.yaml

`schema_list` 仅 `pinyin`（melt_eng 只作词库挂载）。`ascii_composer` 全部切换键为 `noop`，中英切换交给 Lua（D-24 / D-27）。保留 switcher、punctuator、通用 recognizer、基础 key_binder。不包含双拼、简繁 / Emoji 快捷键，以及本机 librime 1.10.0 无效的 navigator / `digit_separators` 等段落。

### 4.2 pinyin.schema.yaml

- processors：`ascii_shift` 在 `ascii_composer` 之前；`ai.trigger` 在 `speller` 之前。
- filters：`ai.suggest` 在 `uniquifier` 之前（消重契约）。
- translators：`script_translator` + `custom_phrase`（`initial_quality: 99` 置顶）+ `melt_eng`（`initial_quality: 1.1`，低于中文 `1.2`）。
- AI 为纯触发式（D-21）；参数段见 schema 的 `ai_suggest:` 与 [candidate-daemon README](../../services/candidate-daemon/README.md)。
- speller 保留标准全拼与超级简拼，不引入模糊音与自动纠错。

### 4.3 词库层

- `pinyin.dict.yaml`：仅 `import_tables`（`cn_dicts/8105`、`base`、`embedded`、`mydict`）+ 既有 A–Z 词条；新增词库只改 import 列表。
- `melt_eng.dict.yaml`：仅 `en_dicts/en`。
- `melt_eng.schema.yaml`：保留文件、不进 `schema_list`。

### 4.4 custom_phrase.txt

`词<Tab>编码<Tab>权重`，固定短语与定制大小写英文。

## 5. vendor 规范

- 来源为 rime-ice（github:Huanfiy/rime-ice）；vendor 后为项目内独立副本，不追随上游。需要时人工 diff。
- vendor 对象：`cn_dicts/8105`、`cn_dicts/base`、`en_dicts/en`、`melt_eng.schema.yaml`、`melt_eng.dict.yaml`。
- 文件头注释记录来源、日期、是否裁剪；写入前去除 UTF-8 BOM（BOM 落在注释后会导致 YAML 解析失败）。
- 仓库内任何文件不得引用 rime-ice 工程的运行时路径（D-4）。

## 6. 部署流程

软链接切换（D-11）。入口 `./run.sh`（`deploy` / `status` / `restart` / `setup`）；`tools/deploy` 为底层实现。

1. `./run.sh deploy` 将 `~/.local/share/fcitx5/rime` 指向本工程 `rime/`；`--to <dir>` 指向其他工程。
2. 只创建 / 重指软链接；遇到真实目录一律停止。
3. `~/.local/share/fcitx5` 本身是真实目录；仅 `rime` 为工程切换软链接。现役状态以 `./run.sh status` 为准。
4. 切换后 `./run.sh restart` 生效；`tools/deploy` 不代为重启。

## 7. 输入学习与多机同步

- 本机学习：`enable_user_dict: true`，userdb 不进 Git（D-1）。
- 词条晋升：按 [lexicon-sop.md](lexicon-sop.md)（D-15）。
- 多机：Git 同步工程源；新机器 `git clone` + `./run.sh setup`；各机 userdb 独立演化（D-6）。本机运行态不写入文档。

## 8. 扩展挂载点

| 扩展 | 挂载方式 | 状态 |
| --- | --- | --- |
| Emoji | vendor `opencc/` + `simplifier@emoji` | 未挂载（D-9） |
| ext 扩展词库 | vendor `cn_dicts/ext` 追加 `import_tables` | 未挂载 |
| octagram | 插件 + `.gram` + schema | 不走 AI 候补轨道（D-18） |
| 语音 | 见 [voice-daemon.md](../plan/voice-daemon.md) | 待实施 |

## 9–12. 已清理

原为计划对照与各阶段一次性验收清单，不属现行事实；编号保留不复用，内容见 git 历史。
