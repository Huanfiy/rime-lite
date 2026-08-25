# AGENTS.md

给在本仓库工作的 AI 与协作者：命令、约束、文档归属。设计正文见 `docs/design/`，不要在此复述。

文档的记录与清理遵循 [docs-rules.md](docs-rules.md)：新增文档前过其记录门槛，改动代码后按其清理准则核查失实文档。

## 项目性质

个人最小 Rime 全拼输入方案（仅 fcitx5）。`rime/` 整目录即部署单元，源文件就是 librime 可直接读取的文件——无构建层、无测试框架、无包管理。验证方式是隔离 staging 构建 + 真机抽查。

已决事项（D-n）与阶段验收见 [docs/design/architecture.md](docs/design/architecture.md) §2 / §10–12。修改配置或词库前先对照，避免推翻已拍板决策。

## 命令

日常操作一律走仓库根目录 `./run.sh`（本机运行态以它的 `status` 为准，不要把激活工程 / 服务是否在位写进文档）：

```bash
./run.sh status                     # 激活工程、daemon、密钥、依赖
./run.sh setup                      # 新机器：检查依赖 → 部署 → 安装 daemon → 配置密钥
./run.sh deploy [--yes]             # 激活本工程（软链接）
./run.sh deploy --to <dir> [--yes]  # 切换到其他 Rime 工程
./run.sh restart                    # fcitx5 -rd
./run.sh verify                     # 隔离 staging 构建，要求零 E 级日志
./run.sh daemon install|start|stop|restart|status|logs
./run.sh apikey                     # 查看当前配置（密钥脱敏）
./run.sh apikey set                 # 写入 / 轮换密钥（不回显、0600）
./run.sh candidates -o /tmp/candidates.tsv <userdb.txt>
```

`tools/deploy` 与 `tools/userdb-candidates` 仍是底层实现，`run.sh` 只做统一入口。

## 必读

| 要改什么 | 先读 |
| --- | --- |
| schema / 词库挂载 / 决策 | [docs/design/architecture.md](docs/design/architecture.md) |
| 加词、userdb 晋升、验证、提交 | [docs/design/lexicon-sop.md](docs/design/lexicon-sop.md) |
| AI 候补结构、契约、运维 | [docs/design/ai-daemon.md](docs/design/ai-daemon.md) |
| daemon 协议与配置字段 | [services/candidate-daemon/README.md](services/candidate-daemon/README.md) |

## 红线

- **中英（D-24）**：左 Shift 按下即英、右 Shift 按下即中。组词中音节左移用右 Shift+Tab 或 Alt+←（左 Shift+Tab 会先切英）。
- **性能（D-19）**：热路径 Lua 预算 ≤ 0.1ms/键，且必须非阻塞；filters 仅 `uniquifier` + `ai.suggest`；零 OpenCC filter。新增功能不得违反。`ascii_shift` 热路径仅 keycode 分支。
- **密钥**：仅存 `~/.config/rime-candidate-daemon/config.json`（0600）。严禁写入仓库任何文件、提交说明或会话落档。泄露则服务商侧作废，再用 `./run.sh apikey set` 写入新密钥。
- **userdb**：禁止对运行中的 `rime/pinyin.userdb/` 执行任何 `rime_dict_manager` 子命令。导出路径见 lexicon-sop.md §3.1。
- **部署**：`~/.local/share/fcitx5/rime` 只允许软链接切换；遇真实目录一律停止，不覆盖、不删除（D-11）。
- **平级工程**：不删除、不修改本机其他 Rime 工程目录（若存在）。是否存在以本机为准，不要在文档里断言路径。
- **词条格式**：Tab 分隔、无 UTF-8 BOM、行尾 LF。`dict.yaml` 表体为 `词<Tab>拼音<Tab>权重`（拼音为空格分隔小写音节）；`custom_phrase.txt` 为 `词<Tab>编码<Tab>权重`。
- **vendor 层**：`cn_dicts/8105`、`cn_dicts/base`、`en_dicts/en` 不手工加词。

## 运行态隔离

`rime/build/`、`rime/*.userdb/`、`rime/sync/`、`installation.yaml`、`user.yaml` 由 `.gitignore` 隔离。一次性中间产物（候选 TSV、staging 目录）放仓库外，不入库。

## Commit 约定

格式 `<emoji> type(scope): subject`（refactor 特例：`♻️refactor(scope): subject`）。type 限 feat / fix / perf / refactor / chore / docs；subject 用中文；一笔一主题。不附加 `Co-Authored-By` 等 AI 署名尾注。

词库改动与文档回写分笔提交。晋升类提交的筛选口径（阈值、剔除数、晋升数）记入提交说明**或** design 文档。清理独立成笔 `🔧 chore`。
