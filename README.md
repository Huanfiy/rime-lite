# rime-lite

个人最小 Rime 全拼输入方案。`rime/` 整目录即部署单元，Git 全量管理，无构建层；热路径零 Lua、零 OpenCC filter。

## 特性

- **全拼简体输入**：《通用规范汉字表》字表（8105）+ 基础词库 + 嵌入式领域词库（602 条）+ 个人词库。
- **英文输入**：挂载 melt_eng 词库，中文方案内直接出英文候选（输入 `hello` 首位即 hello）。
- **固定短语置顶**：`custom_phrase.txt` 缩写码词条固定排在候选首位（`gpio` → GPIO、`zkb` → 占空比）。
- **本机学习 + 词条晋升**：Rime userdb 即时学习；高频词按 SOP 周期性审核晋升进静态词库，跨机经 Git 同步。
- **软链接切换**：与平级 Rime 工程（如 rime-ice）单命令互切，互不修改对方文件。

## 环境要求

- fcitx5-rime 5.1.4 / librime 1.10.0（Ubuntu 系统仓库版本，2026-07-07 验证）。
- `/usr/share/rime-data`（librime-data 包）。

## 快速开始

```bash
git clone <本仓库> ~/sync/rime-lite
cd ~/sync/rime-lite
tools/deploy        # 将 ~/.local/share/fcitx5/rime 软链接指向本工程 rime/
fcitx5 -rd          # 重启 fcitx5 生效
```

`tools/deploy` 只创建 / 重指软链接，遇到真实目录一律停止，不覆盖、不删除。其他用法：

```bash
tools/deploy --status              # 查看当前激活工程
tools/deploy --to <dir> [--yes]    # 切换到其他工程（如 rime-ice）
```

## 目录结构

```text
rime-lite/
├── fact.md              # 事实清单：已决事项与当前状态速查
├── housekeeping.md      # 记录与清理规则（信息治理）
├── README.md
├── docs/                # 文档三层：1-ref 参考输入 / 2-exp 探索过程 / 3-sol 拍板结论
│   └── 3-sol/
│       ├── architecture.md   # 架构设计与决策记录（D-n 编号）
│       └── lexicon-sop.md    # 词库维护 SOP（加词、晋升、验证、提交）
├── rime/                # 部署单元 = Rime 用户目录内容
│   ├── default.yaml
│   ├── pinyin.schema.yaml    # 主方案：全拼
│   ├── pinyin.dict.yaml      # 词库入口（import_tables）
│   ├── melt_eng.schema.yaml  # 英文方案文件（vendor 保留，未列入方案列表）
│   ├── melt_eng.dict.yaml
│   ├── custom_phrase.txt     # 个人固定短语
│   ├── cn_dicts/             # 中文词库（8105 / base / embedded / mydict）
│   └── en_dicts/             # 英文词库（en）
└── tools/
    ├── deploy                # 部署（软链接切换）
    └── userdb-candidates     # userdb 晋升候选分析
```

运行态文件（`rime/build/`、`rime/*.userdb/`、`rime/sync/` 等）由 `.gitignore` 隔离，不进 Git。

## 日常维护

- 加词、userdb 晋升、验证、提交的完整流程：[docs/3-sol/lexicon-sop.md](docs/3-sol/lexicon-sop.md)。
- 当前事实与决策速查：[fact.md](fact.md)。
- 架构设计与决策推导：[docs/3-sol/architecture.md](docs/3-sol/architecture.md)。
- 记录与清理规则：[housekeeping.md](housekeeping.md)。
