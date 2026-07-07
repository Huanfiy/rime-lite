# 词库维护 SOP


| 项    | 内容                                       |
| ---- | ---------------------------------------- |
| 创建日期 | 2026-07-07                               |
| 状态   | 现行（决策 D-15，见 [architecture.md](architecture.md) §2） |
| 适用范围 | rime-lite 词库的长期维护：日常加词、周期性 userdb 晋升、验证与提交 |
| 不覆盖  | 方案（schema）结构调整、新词库类型引入（语法模型、Emoji）、AI 候选（OQ-2） |


## 1. 词库分层与职责


| 文件                       | 承载                        | 修改方式                     |
| ------------------------ | ------------------------- | ------------------------ |
| `cn_dicts/8105`、`cn_dicts/base`、`en_dicts/en` | vendor 基础层             | 不手工加词；同步上游见 §5           |
| `cn_dicts/embedded`      | 嵌入式 / 编程 / AI 领域词         | 手工加词（§2）+ 晋升追加（§3）       |
| `cn_dicts/mydict`        | 非领域个人词（人名、公司、产品、口头语）      | 同上                       |
| `custom_phrase.txt`      | 缩写码固定短语，候选置顶              | 手工加词（§2）                 |
| `rime/pinyin.userdb/`    | 运行态学习缓存（D-1）              | 不手工编辑、不进 Git、不直接操作（§3.1） |


## 2. 日常加词

判定顺序：

1. 需要缩写码直达且置顶（如 `zkb` → 占空比）→ `custom_phrase.txt`，格式 `词<Tab>编码<Tab>权重`（权重可省略）。
2. 全拼输入的领域词 → `cn_dicts/embedded.dict.yaml`，格式 `词<Tab>拼音<Tab>100`（拼音为空格分隔的小写音节，允许单个大写字母音节）。
3. 全拼输入的非领域词 → `cn_dicts/mydict.dict.yaml`，格式同上。

约束与生效：

- Tab 分隔，无 UTF-8 BOM，行尾 LF；写入对应主题分区，或新建带日期的分区注释。
- 任何词库改动需重新部署生效：fcitx5 托盘 → Rime → 重新部署，或 `fcitx5 -rd`。
- 提交按仓库 commit 约定，一笔一主题。

## 3. 周期性 userdb 晋升

建议节奏：按需触发（userdb 学习量明显增长、或高频词反复未进首选时），无固定周期。全流程约半小时，其中人工审定为主要耗时。

### 3.1 导出

**主路径（推荐）**：fcitx5 托盘菜单 → Rime → 同步用户数据，然后读取产物 `rime/sync/<installation_id>/pinyin.userdb.txt`（本机 installation_id 为 `e5a4b25d-3ad3-4900-aaff-ac3786723f3a`，见 `rime/installation.yaml`）。同步触发仅有菜单一种方式：DBus 接口 `org.fcitx.Fcitx.Rime1` 无 Sync 方法，无 CLI 途径（2026-07-07 实测）。

**备选（可脚本化，fcitx5 无需停止）**：

```bash
cp -r rime/pinyin.userdb <工作目录>/
cd <工作目录> && rime_dict_manager -b pinyin
# 产物：<工作目录>/sync/<id>/pinyin.userdb.txt
```

`rime_dict_manager` 以当前工作目录为 Rime 用户目录；复制运行中的 LevelDB 理论上非事务一致，建议先触发一次同步或在输入空闲时复制。

**禁止**：对运行中的 `rime/pinyin.userdb/` 直接执行任何 `rime_dict_manager` 子命令。fcitx5 对 `LOCK` 持排它锁，且 LevelDB 打开动作本身会写 LOG 文件（非只读）；锁被持有时命令报 `E level_db.cc:273] Error opening db` 退出（2026-07-07 实测）。

**不采用**：`rime_dict_manager -e`（导出为三列 `词<Tab>拼音<Tab>次数`，丢失 `d=`/`t=` 元数据，仅适合跨输入法迁移）。

### 3.2 候选分析

```bash
tools/userdb-candidates -o /tmp/candidates.tsv rime/sync/<installation_id>/pinyin.userdb.txt
```

候选 TSV 为一次性中间产物，输出到仓库外（如 `/tmp`），不进 Git。

- 可传多份导出文件（多机 / 多来源），按（词、拼音）合并 c 值。
- 规则同 D-14：丢弃 c ≤ 0；排除单 CJK 字、已收录词（base / 8105 / embedded / mydict / custom_phrase / A–Z 词条）、纯 ASCII 且与拼音串相同的词；门槛 `--min-count` 默认 3。
- 输出 TSV 列：word / pinyin / c_total / 各来源 c / bucket / flag；漏斗统计打印到 stderr。
- bucket 与 flag 仅为启发式建议：fragment 标记对既往晋升词零误报、但对组句残留召回约五成；错词（typo）不做机器判定。**工具输出不可直接应用**。

### 3.3 人工审定

逐条过 TSV，此环节不可省略（D-1 的「审核」）：

- 剔除组句残留（「我需要」「该问题」类，运行态会自然重学，不进静态词库）。
- 剔除错词与临时词；同音异形词（如「落档 / 落挡」）先核实写法再定。
- 复核分桶：领域词 → embedded，非领域 → mydict，需缩写码 → custom_phrase。

### 3.4 应用

- embedded / mydict：文件末尾新建分区 `# ========== userdb 晋升 (YYYY-MM-DD) ==========`，词条 `词<Tab>拼音<Tab>100`，按 c_total 降序。
- custom_phrase：按 §2 格式写入，自定缩写码。
- 同步更新目标文件头部「本地修改」注释（一行记录日期、来源与标准）。

### 3.5 验证

```bash
# 隔离构建（不触碰运行目录），要求零 E 级日志
mkdir -p /tmp/rime-staging && cd /home/huan/sync/rime-lite
rsync -a --exclude build --exclude sync --exclude '*.userdb' \
      --exclude installation.yaml --exclude user.yaml rime/ /tmp/rime-staging/
rime_deployer --build /tmp/rime-staging /usr/share/rime-data
```

排除清单对应 `.gitignore` 运行态段在 `rime/` 下的现存项；运行目录出现新增运行态产物（日志、锁文件等）时同步扩充。

构建通过后重新部署（`fcitx5 -rd`），真机抽查 3~5 个新词条与既有词条（如 `nihao`、`gpio`）确认无回归。

### 3.6 提交

词库改动与文档回写分笔提交，按仓库 commit 约定。本轮筛选口径（阈值、剔除数、晋升数）记入提交说明或 3-sol 文档，便于回溯。

## 4. 多机协同

- 词库经 Git 同步：`git pull` 后重新部署生效；各机 userdb 独立演化，不要求一致（D-6）。
- 他机执行晋升同走本 SOP；installation_id 因机而异，以各机 `rime/installation.yaml` 为准。

## 5. vendor 词库同步上游（低频）

- vendor 层（8105 / base / en / melt_eng）不追随上游自动更新（architecture.md §5）。
- 需要时人工 diff 上游（rime-ice 工程或其远端仓库），确认后更新项目内副本，文件头注释记录新 vendor 日期与裁剪说明，走 §3.5 验证后提交。

## 6. 已知边界

- 导出格式（`拼音<Tab>词<Tab>c= d= t=`）与 `rime_dict_manager` 选项集为 librime 1.10.0 实测行为；librime 升级后需先复核再沿用本 SOP。
- `tools/userdb-candidates` 的排除集读取当前仓库词库；跑历史数据复现需用 `--repo-root` 指向历史版本目录，否则已晋升词条会被排除集吃掉（属预期行为，非工具缺陷）。
