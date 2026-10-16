# 词库维护 SOP

| 项 | 内容 |
| --- | --- |
| 状态 | 现行（D-15，见 [architecture.md](architecture.md) §2） |
| 适用范围 | 日常加词、周期性 userdb 晋升、验证与提交 |
| 不覆盖 | schema 结构调整、新词库类型（语法模型、Emoji）、AI 候补 |

## 1. 词库分层与职责

| 文件 | 承载 | 修改方式 |
| --- | --- | --- |
| `cn_dicts/8105`、`cn_dicts/base`、`en_dicts/en` | vendor 基础层 | 不手工加词；同步上游见 §5 |
| `cn_dicts/embedded` | 嵌入式 / 编程 / AI 领域词 | 手工加词（§2）+ 晋升追加（§3） |
| `cn_dicts/mydict` | 非领域个人词（人名、公司、产品、口头语） | 同上 |
| `en_priority.txt` | 超高频英文 / 命令，中文输入下也整词首选 | 手工加词（§2） |
| `custom_phrase.txt` | 缩写码固定短语，候选置顶 | 手工加词（§2） |
| `rime/pinyin.userdb/` | 运行态学习缓存（D-1） | 不手工编辑、不进 Git、不直接操作（§3.1） |

## 2. 日常加词

判定顺序：

1. 超高频英文 / 命令，中文输入下也要整词首选（如 `gs`、`cd`）→ `en_priority.txt`，格式 `词<Tab>编码<Tab>权重`（权重可省略）。
2. 需要缩写码直达且置顶（如 `zkb` → 占空比）→ `custom_phrase.txt`，格式同上。
3. 全拼输入的领域词 → `cn_dicts/embedded.dict.yaml`，格式 `词<Tab>拼音<Tab>权重`（拼音为空格分隔的小写音节，允许单个大写字母音节）。
4. 全拼输入的非领域词 → `cn_dicts/mydict.dict.yaml`，格式同上。

约束与生效：

- Tab 分隔，无 UTF-8 BOM，行尾 LF；写入对应主题分区，或新建带日期的分区注释。
- 权重按 D-32：先填 100，再跑 `./run.sh candidates --audit`，把列出行的权重改为其 `suggested`（同码静态排序第 2 位）；要压过同码首位时人工改为高于首位权重。`--audit` 只输出表头即合规。
- 词库改动后 `./run.sh restart` 生效。
- 提交按仓库 commit 约定，一笔一主题。

## 3. 周期性 userdb 晋升

按需触发（学习量明显增长、或高频词反复未进首选时）。人工审定不可省略。

### 3.1 导出

**主路径**：fcitx5 托盘 → Rime → 同步用户数据，读取 `rime/sync/<installation_id>/pinyin.userdb.txt`。`installation_id` 见本机 `installation.yaml`，不写入仓库文档。同步无 CLI / DBus 途径。

**备选**（可脚本化，fcitx5 无需停止）：

```bash
cp -r rime/pinyin.userdb <工作目录>/
cd <工作目录> && rime_dict_manager -b pinyin
# 产物：<工作目录>/sync/<id>/pinyin.userdb.txt
```

`rime_dict_manager` 以当前工作目录为 Rime 用户目录；复制运行中的 LevelDB 非事务一致，建议先同步或在输入空闲时复制。

**禁止**：对运行中的 `rime/pinyin.userdb/` 执行任何 `rime_dict_manager` 子命令（fcitx5 持有 `LOCK`，打开即写 LOG）。

**不采用**：`rime_dict_manager -e`（丢失 `d=` / `t=` 元数据）。

### 3.2 候选分析

```bash
./run.sh candidates -o /tmp/candidates.tsv rime/sync/<installation_id>/pinyin.userdb.txt
```

候选 TSV 输出到仓库外，不进 Git。

- 可传多份导出，按（词、拼音）合并 c 值。
- 规则同 D-14：丢弃 c ≤ 0；排除单 CJK 字、已收录词（base / 8105 / embedded / mydict / en_priority / custom_phrase / A–Z）、纯 ASCII 且与拼音串相同的词；门槛 `--min-count` 默认 3。
- 输出列：word / pinyin / c_total / 各来源 c / weight / rivals / bucket / flag。weight 为 D-32 规则建议权重，rivals 为同码 vendor 竞争词前 3 名（词:权重）；bucket / flag 仅为启发式，**不可直接应用**。

### 3.3 人工审定

- 剔除组句残留、错词与临时词；同音异形先核实写法。
- 分桶：纯 ASCII 超高频词 / 命令 → en_priority，领域词 → embedded，非领域 → mydict，需缩写码 → custom_phrase。
- 权重：默认取 weight 列；rivals 首位是生僻词、该词应作首选时，改为高于首位的权重。

### 3.4 应用

- embedded / mydict：末尾新建分区 `# ========== userdb 晋升 (YYYY-MM-DD) ==========`，词条 `词<Tab>拼音<Tab>权重`（§3.3 审定值），按 c_total 降序。
- en_priority / custom_phrase：按 §2 格式写入。
- 更新目标文件头部「本地修改」注释。

### 3.5 验证

```bash
./run.sh candidates --audit   # 自建层权重核查（D-32），要求只有表头
./run.sh verify               # 隔离构建，要求零 E 级日志
./run.sh restart              # 真机抽查 3~5 个新词与既有词（如 nihao、gpio）
```

运行目录出现新的运行态产物时，同步扩充 `.gitignore`。

### 3.6 提交

词库改动与文档回写分笔提交。本轮筛选口径（阈值、剔除数、晋升数）只记入提交说明，不写入 design 文档。

## 4. 多机协同

词库经 Git 同步：`git pull` 后重新部署；各机 userdb 独立演化（D-6）。他机晋升同走本 SOP。

## 5. vendor 词库同步上游（低频）

vendor 层不追随上游自动更新（architecture.md §5）。需要时人工 diff，更新副本并改文件头注释，走 §3.5 验证后提交（vendor 权重变动后 `--audit` 可能列出新行）。

## 6. 已知边界

- 导出格式与 `rime_dict_manager` 选项集以本机 librime 1.10.0 为准；升级后先复核。
- librime 1.10.0 的 userdb 排序（源码与隔离实测，2026-10-16）：同码长时 userdb 词无条件排在全部系统词前，一次上屏即长期前置（衰减不会让它回落）；误上屏的词高亮后 Ctrl+Delete 删除，退回系统词位次。组句按权重比较，userdb 词权重由近期上屏次数决定（每 200 次上屏衰减到 1/e），新造词要在短期内多次上屏才进组句首选。静态权重只决定新机器 / userdb 未覆盖时的排序。
- `tools/userdb-candidates` 排除集读取当前仓库词库；复现历史数据需 `--repo-root` 指向历史版本，否则已晋升词条会被排除。
