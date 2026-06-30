# rime-lite 项目规划

创建日期：2026-06-25  
目标路径：`/home/huan/sync/rime-lite`  
参考项目：`/home/huan/sync/fcitx5/share/rime`

## 1. 项目定位

`rime-lite` 定位为面向个人长期维护的 Rime 全拼输入法工程。项目目标不是复制完整 `rime-ice`，而是在保留基础简体中文输入、Emoji、多机同步、可测试部署能力的前提下，建立一个更适合 Git 管理、后续接入 AI 候选和职业领域词库的最小核心输入系统。

本项目覆盖：

- 全拼简体输入。
- 基础字词库与个人固定短语。
- Emoji 候选。
- 多机同步与部署目录生成。
- 结构化个人词库管理。
- 后续 AI 候选、上下文重排、职业领域词库扩展的预留接口。
- 构建、部署、回归测试、性能测试的闭环。

本项目不覆盖：

- 双拼方案。
- 反查、拆字、农历、计算器、UUID、Unicode 转写等工具型扩展。
- 大型英文词库与复杂中英混输。
- 将 Rime `.userdb` 作为主数据源进行版本管理。
- 每次按键直接调用 LLM。

## 2. 现状问题

现用 Rime 项目功能完整，但存在以下维护成本：

- `schema.yaml` 中同时承载 processors、translators、filters、Lua 扩展、词库策略和快捷键策略，模块边界不清晰。
- `build/`、`.userdb/`、`sync/`、`*.userdb.txt` 等运行态或导出态文件与源配置共处一个目录，Git 变更噪声较大。
- `rime_ice_huan.userdb.txt` 属于全量导出文本，少量输入行为可能引发大段文件改动，不适合作为个人词库的主版本对象。
- 个人职业领域词汇当前主要散落在 `custom_phrase.txt`、`cn_dicts/embedded_huan.dict.yaml`、`cn_dicts/mydict.dict.yaml` 等文件中，缺少统一的来源、标签和变更事件记录。
- 后续 AI 候选若直接塞入 Rime Lua，容易造成按键路径阻塞，不利于延迟控制和故障回退。

## 3. 设计原则

### 3.1 源数据与部署产物分离

仓库内维护结构化源数据，Rime 用户目录只接收生成后的部署产物。

原则：

- `src/`、`personal/`、`tools/`、`tests/` 是主数据。
- `build/`、`deploy/`、`.userdb/`、`sync/` 是生成物或运行物，默认不进入 Git。
- Rime 运行时数据库用于输入体验，不承担长期知识库职责。

### 3.2 Rime 热路径最小化

Rime Lua 只承担低延迟入口和轻量过滤。

原则：

- 按键热路径不读大文件。
- 按键热路径不直接调用 LLM。
- 本地服务调用必须有短超时，目标区间为 20-50 ms。
- 服务异常或超时时回退到 Rime 原始候选。

### 3.3 个人词库可审计

个人词库使用结构化文件和 append-only 事件文件管理。

原则：

- 固定短语、领域词、黑名单、置顶规则分文件存放。
- 输入学习事件按月写入 JSONL。
- 定期将高价值事件压缩为 curated 词库。
- Rime userdb 导出只作为迁移输入，不作为日常版本对象。

### 3.4 功能插件化

核心功能保持小而稳定，扩展功能通过模块挂载。

原则：

- 第一阶段只保留全拼、基础简体、固定短语、Emoji、同步、测试。
- AI 候选、项目上下文、职业领域词库、英文混输作为独立模块接入。
- 每个扩展模块必须声明触发条件、输入输出、超时策略和测试用例。

## 4. 推荐目录结构

```text
rime-lite/
  README.md
  AGENTS.md
  .gitignore

  .agents/
    plans/
      2026-06-25-rime-lite-project-plan.md

  upstream/
    rime-ice/                    # 可选：后续以 submodule 或 vendor 方式保存参考来源

  src/
    schemas/
      huan_pinyin.schema.yaml     # 最小全拼方案模板
    dicts/
      chars.yaml                  # 基础字表源指针或精简副本
      base.yaml                   # 基础词库源指针或精简副本
      domain/
        embedded.yaml             # 嵌入式领域词
        coding.yaml               # 编程领域词
        ai.yaml                   # AI 领域词
    opencc/
      emoji.json
      emoji.txt
    lua/
      init.lua
      filters/
        emoji_tail.lua
      translators/
        script_gateway.lua
      processors/
        hotkey.lua

  personal/
    phrases/
      fixed.yaml                  # 固定短语、短码、邮箱、常用表达
    lexicon/
      curated/
        daily.yaml
        embedded.yaml
        coding.yaml
        ai.yaml
      events/
        2026-06.jsonl             # append-only 输入学习事件
      rules.yaml                  # 置顶、降频、隐藏、黑名单
    context/
      projects.yaml               # 项目 / 目录 / 应用上下文词库策略

  services/
    candidate-daemon/
      protocol.md
      src/
      tests/

  tools/
    build
    deploy
    import-rime-userdb
    compact-lexicon
    smoke
    bench

  tests/
    cases/
      pinyin.tsv
      phrases.tsv
      emoji.tsv
      gateway.tsv
    golden/
    bench/

  build/                          # 生成物，Git 忽略
  deploy/                         # 部署产物，Git 忽略
```

## 5. 核心方案边界

### 5.1 第一阶段保留功能

- `script_translator`：全拼主翻译器。
- `table_translator@fixed_phrase`：固定短语、短码、常用专业缩写。
- `simplifier@emoji`：Emoji 候选。
- `lua_filter@emoji_tail`：Emoji 候选排序控制。
- `uniquifier`：候选去重。
- 基础 punctuation、selector、navigator、editor。

### 5.2 第一阶段剥离功能

- 双拼方案。
- 农历、日期、UUID、计算器、Unicode 等工具型 translator。
- 复杂自动纠错和错音提示。
- 大型英文词库 `melt_eng`。
- 中英混合词库 `cn_en`。
- `cold_word_drop` 运行态降频模块。
- Rime `sync/` 导出的 `*.userdb.txt` 主版本管理。

### 5.3 最小 engine 草案

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
    - table_translator@fixed_phrase
  filters:
    - simplifier@emoji
    - lua_filter@*emoji_tail
    - uniquifier
```

AI 候选接入后，可增加：

```yaml
  translators:
    - lua_translator@*script_gateway
  filters:
    - lua_filter@*candidate_rerank_gateway
```

## 6. 词库管理方案

### 6.1 主数据格式

个人词库建议使用 YAML 和 JSONL。

固定短语示例：

```yaml
- text: STM32
  code: stm
  weight: 90
  tags: [embedded, mcu]
  source: manual

- text: FreeRTOS
  code: freertos
  weight: 80
  tags: [embedded, rtos]
  source: manual
```

输入事件示例：

```jsonl
{"ts":"2026-06-25T10:00:00+08:00","op":"select","input":"gpio","text":"GPIO","context":"embedded","delta":1}
{"ts":"2026-06-25T10:02:00+08:00","op":"pin","input":"stm","text":"STM32","context":"embedded","weight":90}
{"ts":"2026-06-25T10:03:00+08:00","op":"hide","input":"ai","text":"碍","reason":"low_value"}
```

### 6.2 生成目标

构建工具从结构化源数据生成 Rime 可读文件：

```text
build/huan_pinyin.schema.yaml
build/huan_pinyin.dict.yaml
build/fixed_phrase.txt
build/opencc/emoji.json
build/opencc/emoji.txt
build/lua/*.lua
```

生成规则：

- 同一 `text + code` 合并权重。
- `rules.yaml` 中的 hide / drop 优先级高于 curated 词库。
- `fixed.yaml` 权重高于普通领域词。
- 生成结果排序稳定，避免无意义 diff。
- 构建产物默认不提交。

### 6.3 userdb 迁移策略

`*.userdb.txt` 只作为迁移输入：

1. 从现用 Rime 项目导入 `sync/huan_rime/rime_ice_huan.userdb.txt`。
2. 解析出候选文本、编码、词频或权重。
3. 按规则分流到 `personal/lexicon/events/YYYY-MM.jsonl` 或 `personal/lexicon/curated/*.yaml`。
4. 人工审核后删除一次性导入中明显低价值词条。

日常使用阶段不再提交 `*.userdb.txt`。

## 7. 多机同步方案

### 7.1 Git 同步

Git 只同步主数据和工具：

- `src/`
- `personal/`
- `services/`
- `tools/`
- `tests/`
- `.agents/plans/`

不通过 Git 同步：

- `.userdb/`
- `build/`
- `deploy/`
- `sync/`
- Rime 前端生成的锁文件、LevelDB 文件和临时日志。

### 7.2 Rime 原生同步

Rime 原生同步可保留为运行态备份方案，但不作为主版本控制路径。

建议策略：

- 每台机器保留本地 `.userdb`，用于该机器输入学习。
- 定期导出 userdb 后由 `tools/import-rime-userdb` 转为 JSONL 事件。
- 审核后的事件再进入 curated 词库。

### 7.3 部署流程

建议命令：

```bash
tools/build
tools/deploy --target /home/huan/.local/share/fcitx5/rime
```

部署行为：

- 先生成到 `build/`。
- 再复制到目标 Rime 用户目录。
- 不删除目标目录中的 `.userdb/`，除非显式传入危险参数。
- 部署前输出将覆盖的文件列表。

## 8. AI 接入预留

AI 接入采用本地 daemon，不直接进入 Rime Lua 热路径。

### 8.1 Lua 网关职责

- 读取当前输入码。
- 读取 Rime 原候选前 N 项。
- 读取最近上屏上下文的轻量摘要。
- 调用本地 Unix socket 或 localhost HTTP 服务。
- 设置 20-50 ms 超时。
- 超时或异常时返回原候选。

### 8.2 daemon 职责

- 领域词库召回。
- 候选重排。
- 项目上下文感知。
- 输入历史统计。
- 缓存管理。
- 离线词库生成任务。

### 8.3 LLM 使用边界

适合使用 LLM 的场景：

- 从项目 README、代码标识符、Obsidian 笔记中离线提取领域词。
- 根据输入历史生成候选词库优化建议。
- 低频短语扩展。
- 词库清洗和分类。

不适合使用 LLM 的场景：

- 每次按键实时生成候选。
- 无超时保护的候选重排。
- 直接写入个人词库主数据。

## 9. 测试闭环

### 9.1 格式测试

覆盖对象：

- YAML 语法。
- JSONL 单行合法性。
- 词条字段完整性。
- 重复词条检测。
- 非法编码检测。

### 9.2 生成测试

覆盖对象：

- `tools/build` 可重复运行。
- 生成文件排序稳定。
- `schema.yaml` 中核心 engine 不被扩展模块污染。
- `fixed_phrase.txt` 输出符合 Rime table 格式。

### 9.3 输入回归测试

测试用例示例：

```tsv
input	expected_top1	expected_contains
nihao	你好	你好
gpio	GPIO	GPIO
stm	STM32	STM32
freertos	FreeRTOS	FreeRTOS
```

执行方式优先使用 librime 的命令行能力；如果本机工具不足，先实现静态生成测试，再补充集成测试。

### 9.4 性能测试

目标指标：

- 本地构建耗时可记录。
- Lua gateway 正常返回耗时目标为 20-50 ms。
- daemon 异常时 Rime 输入路径不阻塞。
- Emoji 和固定短语不显著增加候选生成延迟。

## 10. 阶段路线

### 阶段 0：项目骨架

目标：

- 创建 Git 仓库。
- 建立 `.agents/plans/`。
- 落档总体规划。
- 建立 `.gitignore`。

完成判定：

- `/home/huan/sync/rime-lite` 已初始化为 Git 仓库。
- 规划文档已落档。

### 阶段 1：最小可部署输入法

目标：

- 生成 `huan_pinyin.schema.yaml`。
- 生成 `huan_pinyin.dict.yaml`。
- 保留基础全拼简体输入。
- 接入 Emoji。
- 可部署到 Fcitx5 Rime 用户目录。

完成判定：

- `nihao`、`shijie`、`gpio` 等基础用例可输入预期候选。
- 重新部署后不依赖现用 Rime 项目的未跟踪运行态文件。

### 阶段 2：结构化个人词库

目标：

- 将现有 `custom_phrase.txt` 转换为 `personal/phrases/fixed.yaml`。
- 将嵌入式、编程、AI 高频词分入 curated 词库。
- 提供稳定生成 `fixed_phrase.txt` 的工具。

完成判定：

- 新增一个个人短语时，Git diff 只出现一小段结构化变更。
- 生成结果可复现。

### 阶段 3：userdb 迁移与同步策略

目标：

- 实现 `tools/import-rime-userdb`。
- 将现有 `rime_ice_huan.userdb.txt` 一次性导入为事件或 curated 词库。
- 明确多机同步流程。

完成判定：

- 不再把 `*.userdb.txt` 作为日常提交对象。
- 多机新增词条可通过 JSONL 或 curated 文件审计。

### 阶段 4：AI 候选实验接口

目标：

- 增加 Lua gateway 草案。
- 增加 daemon 协议文档。
- 实现本地 mock daemon。
- 增加超时回退测试。

完成判定：

- daemon 正常时可插入或重排候选。
- daemon 关闭时基础输入不受影响。

## 11. 待确认问题

以下问题需要在进入阶段 1 前确认：

1. 首版是否完全移除英文输入，还是保留少量固定英文技术词作为 `fixed_phrase`？
2. Emoji 是否沿用 `rime-ice` 的 OpenCC 方案，还是改为结构化源数据后生成 OpenCC 文件？
3. 多机同步的主路径是否确定为 Git，而 Rime 原生同步仅作为迁移和备份输入？
4. 首版部署目标是否只覆盖 `/home/huan/.local/share/fcitx5/rime`，暂不考虑其他平台？
5. 现有 `rime_ice_huan.userdb.txt` 是否需要首轮全量导入，还是只导入人工筛选后的高频职业词？

## 12. 下一步建议

进入阶段 1 前，建议先完成以下决策：

- 确定首版 schema 名称：建议 `huan_pinyin`。
- 确定首版词库来源：建议从 `rime-ice` 保留 `8105`、`base`、`ext`，暂不挂载 `tencent`。
- 确定首版个人词库来源：建议先转换 `custom_phrase.txt`，暂不导入 userdb。
- 确定构建工具语言：建议优先使用 Python 3，便于 YAML / JSONL 处理与后续 AI 工具集成。
