# rime-lite 事实清单

| 项    | 内容                                              |
| ---- | ----------------------------------------------- |
| 更新日期 | 2026-07-07                                      |
| 定位   | 已决事项与当前状态的速查层；设计依据与推导以 [docs/3-sol/](docs/3-sol/) 为准 |

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
- 热路径零 Lua、零 OpenCC filter，filters 仅 `uniquifier`。
- 词库挂载链：`pinyin.dict.yaml` 的 `import_tables` = `cn_dicts/8105`（字表）+ `cn_dicts/base`（基础词库）+ `cn_dicts/embedded`（领域词库，602 条）+ `cn_dicts/mydict`（个人词库，46 条）；另含 26 个大写字母词条。
- `custom_phrase.txt`：个人固定短语（缩写码，如 `gpio` → GPIO、`zkb` → 占空比），`initial_quality: 99` 置顶。
- 本机学习：`enable_user_dict: true`，产出 `rime/pinyin.userdb/`（运行态，不进 Git）。

## 已决事项（详情见 [docs/3-sol/architecture.md](docs/3-sol/architecture.md) §2）

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
- D-15：词库长期维护按 [docs/3-sol/lexicon-sop.md](docs/3-sol/lexicon-sop.md) 执行；晋升分析源自 rime-ice 归档导出扩展为现役 `pinyin.userdb` 导出。

## 阶段与验证状态

- 阶段 0 / 1（骨架、最小可部署输入法）：2026-07-02 完成并验收（architecture.md §10）。
- 阶段 2 / 3（个人词库迁移、userdb 晋升 93 条）：2026-07-07 完成并验收（architecture.md §11）；验证方式为隔离 staging 构建（零 error）+ librime C API 按键探针（12/12 用例）+ Codex 独立交叉审核。
- 词库维护进入长期运营态，流程见 [docs/3-sol/lexicon-sop.md](docs/3-sol/lexicon-sop.md)。

## 未决事项

- OQ-2：AI 候选 daemon 的延迟模型与 Lua socket 可行性（不阻塞现有功能；推导见 [docs/2-exp/analysis/2026-07-01-architecture-open-questions.md](docs/2-exp/analysis/2026-07-01-architecture-open-questions.md)）。
- 本机已装未启用的 librime 插件（2026-07-07 探明，为后续扩展的前置事实）：`librime-plugin-octagram`（n-gram 语法模型，挂载尚缺 `.gram` 模型文件与 schema 配置）；`librime-plugin-lua`（动态链接系统 `liblua5.4`，意味着 Debian 仓库 `lua-socket 3.1.0-1` 理论可加载，OQ-2 探针路径明确，未实测）。
- Emoji、`ext` 扩展词库：挂载点与数据来源已定（architecture.md §8），未挂载。
