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
| `custom_phrase.txt` | 缩写码固定短语，候选置顶 | 手工加词（§2） |
| `rime/pinyin.userdb/` | 运行态学习缓存（D-1） | 不手工编辑、不进 Git、不直接操作（§3.1） |

## 2. 日常加词

判定顺序：

1. 需要缩写码直达且置顶（如 `zkb` → 占空比）→ `custom_phrase.txt`，格式 `词<Tab>编码<Tab>权重`（权重可省略）。
2. 全拼输入的领域词 → `cn_dicts/embedded.dict.yaml`，格式 `词<Tab>拼音<Tab>100`（拼音为空格分隔的小写音节，允许单个大写字母音节）。
3. 全拼输入的非领域词 → `cn_dicts/mydict.dict.yaml`，格式同上。

约束与生效：

- Tab 分隔，无 UTF-8 BOM，行尾 LF；写入对应主题分区，或新建带日期的分区注释。
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
- 规则同 D-14：丢弃 c ≤ 0；排除单 CJK 字、已收录词（base / 8105 / embedded / mydict / custom_phrase / A–Z）、纯 ASCII 且与拼音串相同的词；门槛 `--min-count` 默认 3。
- 输出列：word / pinyin / c_total / 各来源 c / bucket / flag。bucket / flag 仅为启发式，**不可直接应用**。

### 3.3 人工审定

- 剔除组句残留、错词与临时词；同音异形先核实写法。
- 分桶：领域词 → embedded，非领域 → mydict，需缩写码 → custom_phrase。

### 3.4 应用

- embedded / mydict：末尾新建分区 `# ========== userdb 晋升 (YYYY-MM-DD) ==========`，词条 `词<Tab>拼音<Tab>100`，按 c_total 降序。
- custom_phrase：按 §2 格式写入。
- 更新目标文件头部「本地修改」注释。

### 3.5 验证

```bash
./run.sh verify    # 隔离构建，要求零 E 级日志
./run.sh restart   # 真机抽查 3~5 个新词与既有词（如 nihao、gpio）
```

运行目录出现新的运行态产物时，同步扩充 `.gitignore`。

### 3.6 提交

词库改动与文档回写分笔提交。本轮筛选口径（阈值、剔除数、晋升数）只记入提交说明，不写入 design 文档。

## 4. 多机协同

词库经 Git 同步：`git pull` 后重新部署；各机 userdb 独立演化（D-6）。他机晋升同走本 SOP。

## 5. vendor 词库同步上游（低频）

vendor 层不追随上游自动更新（architecture.md §5）。需要时人工 diff，更新副本并改文件头注释，走 §3.5 验证后提交。

## 6. 已知边界

- 导出格式与 `rime_dict_manager` 选项集以本机 librime 1.10.0 为准；升级后先复核。
- `tools/userdb-candidates` 排除集读取当前仓库词库；复现历史数据需 `--repo-root` 指向历史版本，否则已晋升词条会被排除。
