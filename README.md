# rime-lite

个人最小 Rime 全拼输入方案。`rime/` 整目录即部署单元，Git 全量管理，无构建层。热路径 Lua 按预算制约束（D-19，见 [architecture.md](docs/design/architecture.md) §2）。

## 特性

- **全拼简体输入**：《通用规范汉字表》字表（8105）+ 基础词库 + 嵌入式领域词库 + 个人词库。
- **英文输入**：挂载 melt_eng 词库，中文方案内直接出英文候选（输入 `hello` 首位即 hello）。
- **中英切换**：左 Shift 单击切 ASCII，快速双击切中文（Shift+字母仍打大写）。
- **固定短语置顶**：`custom_phrase.txt` 缩写码词条固定排在候选首位（`gpio` → GPIO、`zkb` → 占空比）。
- **本机学习 + 词条晋升**：Rime userdb 即时学习；高频词按 SOP 周期性审核晋升进静态词库，跨机经 Git 同步。
- **AI 智能候补**：组词中按 `Tab` 显式请求（纯触发式，不按键零上云）；daemon 缺席时自动降级为原生体验。
- **软链接切换**：与平级 Rime 工程单命令互切，互不修改对方文件。

## 环境要求

- fcitx5-rime 5.1.4 / librime 1.10.0（Ubuntu 系统仓库；包名锚点 `librime1t64 1.10.0+dfsg1-2build2`）。
- `/usr/share/rime-data`（librime-data 包）。
- AI 候补另需：`librime-plugin-lua`、`lua-socket`、Python 3（仅标准库）。漏装时 AI 通路静默降级，无日志指向根因。

## 快速开始

```bash
git clone <本仓库> ~/sync/rime-lite
cd ~/sync/rime-lite
./run.sh setup          # 检查依赖、激活本工程、安装 daemon
./run.sh apikey set     # 写入 OpenAI 兼容 API 密钥（0600，不入库）
./run.sh restart        # 重启 fcitx5 生效
```

只启用输入法、不要 AI 通路时：

```bash
./run.sh deploy
./run.sh restart
```

`./run.sh deploy` 只创建 / 重指软链接，遇到真实目录一律停止，不覆盖、不删除。本机当前激活工程、daemon 与密钥状态：

```bash
./run.sh status
```

## 目录结构

```text
rime-lite/
├── AGENTS.md            # AI / 协作者入口：命令、禁区、决策指针
├── docs-rules.md        # 记录与清理规则
├── run.sh               # 统一入口：部署、验证、daemon、密钥
├── README.md
├── docs/
│   ├── design/              # 现行架构、决策、SOP
│   └── plan/                # 已评审待实施（落地后搬入 design）
├── rime/                # 部署单元 = Rime 用户目录内容
│   ├── default.yaml
│   ├── pinyin.schema.yaml
│   ├── pinyin.dict.yaml
│   ├── custom_phrase.txt
│   ├── lua/ascii_shift.lua  # 左 Shift 单击 ASCII / 双击切中（D-27）
│   ├── lua/ai/          # AI 候补 glue / trigger / suggest
│   ├── cn_dicts/
│   └── en_dicts/
├── services/
│   └── candidate-daemon/     # AI daemon、配置示例、协议说明
└── tools/
    ├── deploy
    └── userdb-candidates
```

运行态文件（`rime/build/`、`rime/*.userdb/`、`rime/sync/` 等）由 `.gitignore` 隔离，不进 Git。密钥只在 `~/.config/rime-candidate-daemon/config.json`。

## 日常维护

- 统一入口与本机状态：`./run.sh` / `./run.sh status`。
- 加词、userdb 晋升、验证、提交：[docs/design/lexicon-sop.md](docs/design/lexicon-sop.md)。
- 架构与决策：[docs/design/architecture.md](docs/design/architecture.md)。
- AI 候补：[docs/design/ai-daemon.md](docs/design/ai-daemon.md)。
- 协作约定：[AGENTS.md](AGENTS.md)。
- 记录与清理：[docs-rules.md](docs-rules.md)。
