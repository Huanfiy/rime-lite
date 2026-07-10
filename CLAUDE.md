# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目性质

个人最小 Rime 全拼输入方案（fcitx5 平台）。`rime/` 整目录即部署单元，源文件就是 librime 可直接读取的文件——**无构建层、无测试框架、无包管理**。验证方式是隔离 staging 构建 + 真机抽查（见下）。

当前事实与已决事项（D-n 编号）以 [fact.md](fact.md) 为速查入口，设计推导见 [docs/design/architecture.md](docs/design/architecture.md)。修改配置或词库前先对照 fact.md，避免推翻已拍板决策。

## 常用命令

```bash
tools/deploy --status              # 查看当前激活的 Rime 工程
tools/deploy                       # 激活本工程（重指 ~/.local/share/fcitx5/rime 软链接）
tools/deploy --to <dir> [--yes]    # 切换到其他工程（如 /home/huan/sync/rime-ice）
fcitx5 -rd                         # 重启 fcitx5，使部署/词库改动生效（脚本不代为执行）
```

验证（相当于本仓库的「测试」，词库或 schema 改动后必跑，要求零 E 级日志）：

```bash
mkdir -p /tmp/rime-staging
rsync -a --exclude build --exclude sync --exclude '*.userdb' \
      --exclude installation.yaml --exclude user.yaml rime/ /tmp/rime-staging/
rime_deployer --build /tmp/rime-staging /usr/share/rime-data
```

userdb 晋升候选分析（只读工具，输出到仓库外；结果必须人工审定，不可直接入库）：

```bash
tools/userdb-candidates -o /tmp/candidates.tsv rime/sync/<installation_id>/pinyin.userdb.txt
```

## 架构

- **部署拓扑**：`~/.local/share/fcitx5/rime` 是软链接，指向当前激活工程的配置目录；工程切换 = 重指链接。`tools/deploy` 只创建 / 重指软链接，遇真实目录一律停止，不覆盖、不删除。
- **词库挂载链**：`pinyin.dict.yaml` 经 `import_tables` 挂载 `cn_dicts/8105`（字表）、`cn_dicts/base`（基础词库）、`cn_dicts/embedded`（领域词）、`cn_dicts/mydict`（个人词）与 `en_dicts/en`（经 melt_eng）。melt_eng 仅作词库挂载出英文候选，不是独立方案；启用方案仅 `pinyin`。
- **词库分层**：8105 / base / en 为 vendor 层，不手工加词；embedded / mydict / `custom_phrase.txt` 为个人层，手工维护。加词判定顺序、格式与分区规则见 [docs/design/lexicon-sop.md](docs/design/lexicon-sop.md) §2。
- **userdb 生命周期**：`rime/pinyin.userdb/` 仅是本机学习缓存（运行态，不进 Git）；稳定词条走「导出 → `tools/userdb-candidates` 机械筛选 → 人工审定 → 晋升静态词库 → Git」（D-1 / D-14 / D-15）。
- **AI 智能候补通路**（D-18 / D-21 纯触发式，设计见 [docs/design/ai-daemon.md](docs/design/ai-daemon.md)）：`rime/lua/ai/` ↔ unix socket ↔ `services/candidate-daemon/`（systemd 用户服务 `rime-candidate-daemon`）↔ OpenAI 兼容 API，组词中按 `Tab` 显式请求生成式候补（上下文整句转换 + 延伸预测）注入候选栏，不按键零外发（无自动预取）；密钥仅存 `~/.config/rime-candidate-daemon/config.json`（0600），**严禁写入仓库任何文件**；daemon 缺席时输入法自动降级为原生体验。
- **性能红线**（预算制，D-19）：热路径 Lua 预算 ≤ 0.1ms/键，且必须非阻塞（不等待 daemon / 网络）；filters 仅 `uniquifier` + `ai.suggest`；零 OpenCC filter；新增功能不得违反。
- **运行态隔离**：`rime/build/`、`rime/*.userdb/`、`rime/sync/`、`installation.yaml`、`user.yaml` 由 `.gitignore` 隔离；一次性中间产物（候选 TSV、staging 目录）放仓库外，不入库。

## 关键禁区

- **禁止**对运行中的 `rime/pinyin.userdb/` 执行任何 `rime_dict_manager` 子命令——fcitx5 持有 LevelDB 排它锁，且打开动作本身非只读。正确的导出路径见 lexicon-sop.md §3.1。
- 不删除、不修改平级工程 `/home/huan/sync/rime-ice`（备胎工程，rime-lite 稳定运行前保留）。
- 词条格式：Tab 分隔、无 UTF-8 BOM、行尾 LF；dict.yaml 表体为 `词<Tab>拼音<Tab>权重`（拼音为空格分隔小写音节），`custom_phrase.txt` 为 `词<Tab>编码<Tab>权重`。

## 文档治理

文档改动受 [docs-rules.md](docs-rules.md)（D-16）约束，核心规则：

- 工作区只保留**当前事实**与**未决过程**，历史由 git 承担；AI 会话产出默认**不记录**，落档需过记录门槛（面向未来读者、不可从代码 / git 推导、有唯一归属层）。
- 同一事实只允许一处正文，其余位置用链接指向；配置内容不复述进文档（引用文件路径即可）。
- 文档三层：`docs/refs/`（待消费的外部材料，消费后清理）、`docs/notes/`（未决决策的推导，拍板后清理）、`docs/design/`（拍板结论与 SOP，就地更新）。
- 决策 / 阶段变更时同轮更新 `fact.md`；被推翻的决策行不删除，原地标注「已被 D-m 推翻」。

## Commit 约定

格式 `<emoji> type(scope): subject`（refactor 特例：`♻️refactor(scope): subject`），type 限 feat / fix / perf / refactor / chore / docs，subject 用中文，一笔一主题。词库改动与文档回写分笔提交；晋升类提交在说明中记录筛选口径（阈值、剔除数、晋升数）。清理独立成笔 `🔧 chore` 提交。
