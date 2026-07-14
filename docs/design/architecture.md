# rime-lite 最小配置架构


| 项         | 内容                                                                                       |
| --------- | ---------------------------------------------------------------------------------------- |
| 创建日期      | 2026-07-02                                                                               |
| 状态        | 已拍板，作为首版实施依据                                                                             |
| 决策推导      | `docs/notes/analysis/2026-07-01-architecture-open-questions.md`（已移出工作区，git 历史 `f8bc790` 可查）      |
| 原始计划      | `.agents/plans/2026-06-25-rime-lite-project-plan.md`（已移出工作区，git 历史 `d764656` 可查）         |
| vendor 来源 | rime-ice 工程，现位于 `/home/huan/sync/rime-ice`（vendor 当日位于 `/home/huan/sync/fcitx5/share/rime`，2026-07-02 迁出） |
| 部署目标      | `/home/huan/.local/share/fcitx5/rime`                                                    |


## 1. 定位与范围

首版目标：一个可整目录部署、不依赖外部 rime-ice 工程路径、Git 全量管理的最小全拼输入方案。

**首版覆盖：**

- 全拼简体中文输入（字表 + 基础词库）。
- 英文输入（挂载 melt_eng 词库，中文方案内出英文候选；独立英文方案已于 2026-07-02 移出方案列表，git `e4aab2b`）。
- 个人固定短语（`custom_phrase.txt`，Rime 原生格式）。
- 本机输入学习（Rime userdb，仅作运行态缓存）。
- 单命令激活：fcitx5 的 Rime 用户目录软链接指向本工程 `rime/`，可与 rime-ice 双向切换。

**首版不覆盖：**

- Emoji（数据来源已确认，挂载推迟，见第 8 节）。
- 扩展词库 `ext`、腾讯词库等大词库。
- 置顶 / 隐藏 / 降频规则层（已确认永久移除）。
- Lua 脚本（首版零 Lua；2026-07-08 起 AI 候选通路按预算制挂载，D-18 / D-19）。
- AI 候选 daemon（首版未决；2026-07-08 已落地，D-18）。
- 双拼、反查、日期、计算器等工具型扩展。
- fcitx5 以外的部署平台。

## 2. 决策记录

2026-07-01 评审已确认的结论（推导过程已移出工作区，git 历史 `f8bc790` 可查）：


| 编号   | 决策                                                                       |
| ---- | ------------------------------------------------------------------------ |
| D-1  | 不自建 `events/*.jsonl`；userdb 仅作本机学习缓存，稳定词条走「导出 → 审核 → 晋升静态词库 → Git」        |
| D-2  | userdb 晋升分析源仅限 `sync/huan_rime/` 下两份导出文本（阶段 3 消费后已移出工作区，git 历史 `6438887` 可查），只筛选高价值词条，不全量导入 |
| D-3  | 不保留置顶 / 隐藏机制（`pin_cand_filter`、`cold_word_drop` 及任何替代规则层）                 |
| D-4  | 基础词库采用项目内副本，集中放入 `char-lib/`（后经 D-12 更名 `cn_dicts/`），构建与部署不得依赖外部 rime-ice 路径 |
| D-5  | 个人词库使用 Rime 原生格式（`custom_phrase.txt` + `dict.yaml`），不引入 YAML → dict 构建层   |
| D-6  | Git 同步工程源为主路径；Rime 原生同步仅作运行态备份与迁移输入（OQ-10）                                |


2026-07-02 拍板的新增决策：


| 编号   | 决策                                             | 说明                                                              |
| ---- | ---------------------------------------------- | --------------------------------------------------------------- |
| D-7  | 挂载 melt_eng 英文词库                               | 推翻 OQ-9 原倾向（仅固定英文技术词）。理由：日常英文输入量不可忽略，仅靠 `custom_phrase` 固定词条不可接受 |
| D-8  | 首版方案命名 `huan_pinyin`                           | 采用原计划 §12 建议，个人专属工程属性优先（已被 D-12 推翻）                              |
| D-9  | Emoji 不进首版                                     | OQ-8 的数据来源结论（vendor rime-ice opencc 文件）保持有效，仅挂载时机推迟             |
| D-10 | 部署范围仅 `/home/huan/.local/share/fcitx5/rime`    | 确认 OQ-11 倾向                                                     |
| D-11 | 部署方式为软链接切换                                   | fcitx5 用户目录 `rime` 为软链接，指向当前激活工程的配置目录；rime-lite 与 rime-ice 为平级工程，切换 = 重指链接，互不修改对方文件 |
| D-12 | 命名简化：`huan_pinyin` → `pinyin`，`char-lib/` → `cn_dicts/` | 推翻 D-8：schema_id、词库入口、显示名统一为 `pinyin`，去除个人前缀；`cn_dicts/` 回归 rime-ice 目录命名约定。userdb 学习数据经 `rime_dict_manager` 导出 / 导入无损迁移（168 条） |


2026-07-07 拍板的新增决策：


| 编号   | 决策                | 说明                                                              |
| ---- | ----------------- | --------------------------------------------------------------- |
| D-13 | 个人领域词库合并挂载（阶段 2） | rime-ice 的 `embedded` 与 `embedded_huan` 合并为单一 `cn_dicts/embedded.dict.yaml`（同词同音去重取高权重，552 条）；`mydict.dict.yaml` 原样迁移（3 条）；均经 `pinyin.dict.yaml` 的 `import_tables` 挂载 |
| D-14 | userdb 晋升标准（阶段 3） | 分析源为 rime-ice 两份 userdb 导出（D-2，git 历史 `6438887`）；按（词、拼音）合并两份 c 值，门槛 c_total ≥ 3；排除 c ≤ 0、单字、已收录词（base / 8105 / embedded / mydict / custom_phrase / A–Z 词条）；人工剔除组句残留与错词；晋升词条以 `# ========== userdb 晋升 (日期) ==========` 分区追加至目标词库，统一权重 100 |
| D-15 | 词库长期维护流程 SOP 化 | 日常加词与周期性晋升按 [lexicon-sop.md](lexicon-sop.md) 执行；晋升分析源自 rime-ice 归档导出扩展为现役 `pinyin.userdb` 导出（Rime 原生同步产物为主路径）；候选分析固化为 `tools/userdb-candidates`（机械筛选，D-14 规则），人工审定环节不可省略 |
| D-16 | 记录与清理规则落档 | 信息治理规则见根目录 [docs-rules.md](../../docs-rules.md)：工作区只保留当前事实与未决过程，历史由 git 承担；记录门槛、清理触发点 / 判据 / 方式及既有先例见该文件 |


2026-07-08 拍板的新增决策：


| 编号   | 决策                | 说明                                                              |
| ---- | ----------------- | --------------------------------------------------------------- |
| D-17 | AI daemon 延迟模型为「按需触发 + 异步预取」（OQ-2 选项 1） | 热路径任何情况下不等待 daemon：lua filter 仅做非阻塞收发与缓存查表（µs 级），结果展示以专用触发键为主入口（对在途结果有界等待并强制刷新）。依据：2026-07-08 Lua socket 能力探针实测通过——librime-lua 内 luasocket 可用（关键前置：先 `package.loadlib(liblua5.4, "*")` 再 require），unix RTT p50 11.9µs，超时可硬性封顶，daemon 缺席 30µs 内降级。实测与实施推导已移出工作区（git 历史 `0ca9348` 可查）；工作负载与协议同日由 D-18 拍板落地 |
| D-18 | AI 候选工作负载 = LLM 生成式智能候补，经 OpenAI 兼容 API（同日实现落地） | 用户诉求「更聪明、懂我」且要**预测式候补**（猜后续输入），不受本地词库限制；octagram 对照结论：局部 n-gram 不覆盖跨句语境诉求，不走该轨道。行为：daemon 根据会话上下文生成 ≤ 3 条候补（拼音整句转换 + 延伸预测，如上屏「嵌入式系统」后输入 `zhongduan` → 「中断处理程序」），注入候选栏首位（⚡ 标记，选中即整段上屏），本地候选跟随（重文由 uniquifier 消重）。构成：`rime/lua/ai/`（suggest filter + trigger processor + glue）↔ unix socket ↔ `services/candidate-daemon/`（systemd 用户服务，密钥托管于 `~/.config/rime-candidate-daemon/config.json`，不入库）↔ 云端 API。参数：模型默认 `gpt-5.4` + `reasoning_effort: low`（模型子项已被 D-22 推翻；生成实测 2.7~4.8s、方差小、~60 输出 token；曾按「选最快」用 spark，因推理 token 烧量大 / 方差 1.7~7s 于同日调整）；`ai_suggest` 开关默认开 = 长度 ≥ 4 的稳定态自动预取（daemon 去抖 300ms），关闭 = trigger-only 隐私模式（自动预取与开关子项已被 D-21 推翻：全局纯触发式，开关撤销）；触发键 `Tab`（仅组词状态拦截，原音节右移绑定让位——Ctrl+t 常被应用抢占，同日调整；有界等待 250ms）；会话上下文为近期上屏 ≤ 6 条（`commit_notifier` 通报）。演进注：当日初版为重排式（只调本地候选顺序），用户验收判定不满足诉求，同日改为生成式候补并复验。协议 v1.1（NDJSON over UDS）与运行参数见 [services/candidate-daemon/README.md](../../services/candidate-daemon/README.md) |
| D-19 | 性能红线修订为预算制 | 原「热路径零 Lua」与 D-18 定义性冲突，修订为：**热路径 Lua 预算 ≤ 0.1ms/键**（实测口径）；filters 仅 `uniquifier` + `ai.suggest`，processors 新增 `ai.trigger`，全部非阻塞、daemon 缺席 µs 级降级；零 OpenCC filter 维持不变。M0 实测：开关开/关差值 ≤ 0.04ms/键（§12），远低于预算 |


2026-07-09 拍板的新增决策：


| 编号   | 决策                | 说明                                                              |
| ---- | ----------------- | --------------------------------------------------------------- |
| D-20 | AI 触发架构并发化 + 两拍触发契约（协议 v1.2） | 动因（2026-07-08 journal 观测）：daemon 串行 `api_lock` 使新请求排在半截前缀调用之后（随机 +0~6s），结果普遍落在上屏之后作废；触发键有界等待 250ms < 去抖 300ms，冷启动首按必空且无反馈。改造（API 延迟视为固定秒级，不触碰 D-17 无异步刷新与 D-19 预算红线）：**daemon 调度**——去串行锁改并发槽（`max_concurrency` 默认 3，HTTP 连接池摊销 TLS）+ 同 key 在途防重 + commit 作废所有在队请求（去抖中 + 等并发槽的，含 explicit，2026-07-09 扩展；在途 API 不中断，回包由客户端按 key 失配丢弃）+ auto 请求音节完整门控（悬空辅音结尾如 `chak`/`houb` 不上云，只看尾字符、宽容误收）；**explicit 快车道**——触发键请求带 `explicit` 标记跳过门控与去抖，端到端 = API 净耗时；**两拍契约**——Tab 未命中亮 `⚡…` 段提示（有界等待仅兜近落地结果，带 1s 冷却使长按 = 轮询、不积压事件队列）；**阈值分离**——自动预取 `auto_min_length: 6`，注入 / 触发维持 `min_length: 4`；**协议 v1.2**——请求增 `explicit` / `prefix` 字段、`pinyin` 改为当前翻译段（修复选定首词后候补重复已选前缀的缺陷），v1.1 客户端按 auto 兼容。（auto 路径子项——音节门控 / 去抖 / 阈值分离 / explicit 字段——已被 D-21 推翻：auto 路径整体移除，explicit 快车道升格为唯一路径；并发槽 / 同 key 防重 / commit 作废 / 两拍契约保留现行。）验证：mock e2e 六项调度行为（explicit 快车道 / 去抖 / 门控 / explicit 越过门控 / 新输入取代 / commit 作废）+ 客户端 payload 与重试单测 + staging 构建零 E；真机 `⚡…` 提示重绘与两拍收割节奏 2026-07-09 抽查确认 |


2026-07-09 晚间拍板的新增决策：


| 编号   | 决策                | 说明                                                              |
| ---- | ----------------- | --------------------------------------------------------------- |
| D-21 | 撤销自动预取，AI 候补纯触发式（协议 v1.3） | 动因（2026-07-09 用户使用反馈）：正常打字几乎见不到 AI 候补——librime 无异步刷新通道（D-17），预取结果不能自行弹出，须再按键（事实上只有 Tab）才展示；而 API 延迟 2.7~4.8s 落后于打字节奏，auto 产出几乎总在上屏后作废。自动预取的全部价值仅剩「停顿后按 Tab 省一拍」，代价却是持续自动上云 + token 消耗，判定不成立，整体撤销。改造：**daemon**——移除 auto 路径（音节完整门控、去抖、`latest_auto` 取代逻辑；`debounce_ms` 配置废弃，出现即忽略），所有 suggest 直达并发槽；**filter**（`ai/suggest.lua`）——只收包 + 查缓存注入，不再发预取请求（commit 上下文通报保留；本会话从未按过触发键时直通透传，不碰 socket）；**开关**——`ai_suggest` 从 switches 撤销（trigger-only 即全局语义，隐私边界 = 不按 Tab 零上云；`ai_suggest:` 配置段保留，删 `auto_min_length`）；**协议 v1.3**——移除 `explicit` 字段（旧字段被忽略，v1.1 / v1.2 请求一律按显式处理）。保留：并发槽 + 同 key 防重 + commit 作废在队请求、两拍触发契约与 `⚡…` 提示（均沿 D-20）；`min_length` 初期沿 D-20 值 4，2026-07-10 调为 1——该门槛原为约束自动外发而设，纯触发式下失去保护对象，Tab 即触发。验证：mock e2e（直达并发槽零去抖延迟 / 悬空辅音不再拦截 / 同 key 防重 / commit 作废在队请求）+ glue payload 断言（无 explicit 字段）+ staging 构建零 E |


2026-07-14 拍板的新增决策：


| 编号   | 决策                | 说明                                                              |
| ---- | ----------------- | --------------------------------------------------------------- |
| D-22 | GPT-5.6 Fast 模型与精简提示词 | 系统提示词限制 ≤ 100 字（提示词长度子项已被 D-23 推翻）；95 字纯规则版无法稳定识别 `fushanjingtiguan`，最终 99 字版保留一条真实领域歧义样例。以 `reasoning_effort: low`（中转可接受的最低档）+ `service_tier: priority` 对 Luna / Terra / Sol 交错测试五类样例：Luna 4/5（`gpio` 错作「通用输入输出」），中位 / 均值 / 最大延迟 5.012 / 5.324 / 9.178s；Terra 5/5，3.131 / 3.409 / 4.961s；Sol 5/5，2.784 / 3.198 / 4.751s。选择 `gpt-5.6-sol`；Priority 被当前 OpenAI 兼容中转接受但响应未回显 `service_tier`，故只确认参数兼容，不把上游实际 tier 作为已证事实。 |
| D-23 | 表情意图候补与提示词扩容 | 系统提示词上限放宽为 200 字，现行为 195 字：首项始终为转写；识别到表情意图时第 2、3 项仅输出匹配语义的 emoji / 颜文字，否则维持 ≤ 10 字延伸；同时保留轻微拼音误写纠正。真 API 抽查：`keaidebiaoqing` 与误拼 `keaidebiaoqiang` 均得「可爱的表情 / 🥰 / (｡･ω･｡)ﾉ♡」，未入示例的 `kaixindebiaoqing` 得「开心的表情 / 😄 / ٩(ˊᗜˋ*)و」；`fushanjingtiguan`、`shanjidianya` 专业回归通过。 |


未决事项：无阻塞项。AI 候选通路 M2 收尾见 [ai-daemon.md](ai-daemon.md) §8；运行参数（模型 / 去抖 / 上下文规模）走 daemon 配置文件调优，不动仓库。

## 3. 仓库目录结构

```text
rime-lite/
├── docs/                        # 文档（ref / exp / sol 三段式）
├── rime/                        # 部署单元：整目录同步到 Rime 用户目录
│   ├── default.yaml             # 全局配置：方案列表、菜单、方案选单
│   ├── pinyin.schema.yaml       # 主方案：全拼
│   ├── pinyin.dict.yaml         # 主词库入口：仅 import_tables，不含词条
│   ├── melt_eng.schema.yaml     # 独立英文方案（vendor）
│   ├── melt_eng.dict.yaml       # 英文词库入口（vendor，裁剪）
│   ├── custom_phrase.txt        # 个人固定短语（Rime 原生 table 格式）
│   ├── cn_dicts/                # 中文词库项目内副本（D-4，D-12 更名）
│   │   ├── 8105.dict.yaml       # 字表
│   │   ├── base.dict.yaml       # 基础词库
│   │   ├── embedded.dict.yaml   # 个人领域词库（D-13，2026-07-07 挂载）
│   │   └── mydict.dict.yaml     # 个人自定义词库（D-13，2026-07-07 挂载）
│   ├── en_dicts/
│   │   └── en.dict.yaml         # 英文主词库（vendor）
│   └── lua/                     # AI 候选通路（D-18；红线预算制见 D-19）
│       ├── ai/                  # glue（socket/缓存）、rerank（filter）、trigger（processor）
│       └── vendor/json.lua      # vendor rxi/json.lua（协议编解码）
├── services/
│   └── candidate-daemon/        # AI 候选 daemon（D-18）：daemon、systemd 单元、README（协议 v1）
├── tools/
│   ├── deploy                   # 部署脚本，行为约定见第 6 节
│   └── userdb-candidates        # userdb 晋升候选分析（D-15，用法见 lexicon-sop.md §3.2）
└── .gitignore
```

结构要点：

- **无构建层**。依据 D-5，`rime/` 目录内即 Rime 可直接读取的源文件，部署等于复制。原计划 §4 的 `src/ → build/ → deploy/` 三层结构随构建层一并取消；后续若引入生成型词库，再恢复分层。
- **`cn_dicts/` 与 `en_dicts/` 分置**。D-4 原命名 `char-lib/`（形成于英文词库尚在剥离范围时，仅约束中文基础词库），D-12 更名 `cn_dicts/` 后与 `en_dicts/` 一并回归 rime-ice 的目录命名约定；vendor 的 `melt_eng.dict.yaml` 中 `import_tables` 路径始终无需改动。
- **中文基础词库首版仅 `8105`（字表）+ `base`（基础词）**。`ext` 为可选扩展，挂载方式见第 8 节；`tencent` 不引入（沿用原计划 §12）。
- 词库子目录只用单层路径（`cn_dicts/8105`、`en_dicts/en`），与 rime-ice 的 `import_tables` 用法一致，不引入多层嵌套。
- **`rime/` 同时是激活后的运行目录**（D-11）。Rime 运行态（`build/`、`*.userdb/`、`sync/`、`installation.yaml`、`user.yaml`）写入 `rime/` 内，由 `.gitignore` 隔离，不进 Git。

## 4. 模块设计

### 4.1 default.yaml

以 vendor 源 `default.yaml` 为基础裁剪，仅保留：

```yaml
schema_list:
  - schema: pinyin        # melt_eng 仅作词库挂载，不作独立方案（2026-07-02 调整，git e4aab2b）
menu:
  page_size: 5
```

另保留：方案选单（switcher）、ASCII 切换（ascii_composer）、标点映射（punctuator，供方案以 `import_preset: default` 引用）、通用 recognizer patterns（email / url / underscore）、基础 key_binder（光标移动、`-` / `=` 翻页、中英标点切换）。

移除：双拼方案项、简繁 / Emoji / Lua 相关快捷键，以及在本机 librime 1.10.0（fcitx5-rime 5.1.4）上无效的段落——navigator（需 librime >= 1.16.0）、`punctuator/digit_separators`（需 librime >= 1.13.0）。

### 4.2 pinyin.schema.yaml

engine 定案（首版零 Lua、零 OpenCC filter；2026-07-08 起 AI 候选通路按 D-18 挂载、红线转预算制 D-19）：

```yaml
engine:
  processors:
    - ascii_composer
    - recognizer
    - key_binder
    - lua_processor@*ai.trigger      # AI 候补触发键（D-18）
    - speller
    - punctuator
    - selector
    - navigator
    - express_editor
  segmentors:
    - ascii_segmentor
    - matcher            # 响应 recognizer 的 patterns（email、url 等）
    - abc_segmentor
    - punct_segmentor
    - fallback_segmentor
  translators:
    - punct_translator
    - script_translator
    - table_translator@custom_phrase
    - table_translator@melt_eng
  filters:
    - lua_filter@*ai.suggest         # AI 智能候补注入（D-18，非阻塞）
    - uniquifier
```

AI 候选通路为纯触发式（D-21，无开关、无自动预取），参数段（`ai_suggest:` 键位 / 阈值 / 等待）与行为语义见 `rime/pinyin.schema.yaml` 及 [services/candidate-daemon/README.md](../../services/candidate-daemon/README.md)。

关键配置块（字段值以 vendor 源为基准，已核对）：

```yaml
translator:                  # 主翻译器：全拼
  dictionary: pinyin
  enable_user_dict: true     # 本机学习缓存，产出 userdb，不进 Git（D-1）
  initial_quality: 1.2       # 拼音权重高于 melt_eng

custom_phrase:               # 个人固定短语
  dictionary: ""
  user_dict: custom_phrase   # 读取 custom_phrase.txt
  db_class: stabledb
  enable_completion: false
  enable_sentence: false
  initial_quality: 99        # 高于拼音与 melt_eng，固定短语排序在前

melt_eng:                    # 英文词库挂载（D-7）
  dictionary: melt_eng
  enable_sentence: false
  enable_user_dict: false
  initial_quality: 1.1       # 低于中文候选，英文词不抢占首选
  comment_format:
    - xform/.*//
```

speller 保留标准全拼拼写规则（含 v / ü 转换）与超级简拼（abbrev 及配套 erase 规则，沿用 rime-ice），不引入模糊音与自动纠错。

### 4.3 词库层

- `pinyin.dict.yaml`：入口文件，`import_tables: [cn_dicts/8105, cn_dicts/base, cn_dicts/embedded, cn_dicts/mydict]`（后两项为阶段 2 挂载，D-13）；除迁移自现用工程的 26 个大写字母词条（Shift + 字母输入、大写字母参与造句）外不含词条。新增词库时只改此文件的 import 列表。
- `melt_eng.dict.yaml`：vendor 后裁剪，`import_tables` 仅保留 `en_dicts/en`，移除 `en_dicts/en_ext`。
- `melt_eng.schema.yaml`：vendor 英文方案文件，无 Lua 依赖；2026-07-02 起移出 `schema_list`（git `e4aab2b`），仅保留文件，melt_eng 词库经主方案 `table_translator@melt_eng` 挂载。

### 4.4 custom_phrase.txt

Rime 原生 table 格式（`词条<Tab>编码<Tab>权重`），承载个人固定短语与英文技术词的定制写法（如 `GPIO`、`FreeRTOS` 的固定大小写）。初始内容从现用工程 `custom_phrase.txt` 人工筛选迁移，不整文件照搬。

## 5. vendor 规范

- 来源固定为 rime-ice 工程本机版本（2026-07-02 起位于 `/home/huan/sync/rime-ice`，远端 github:Huanfiy/rime-ice；vendor 当日位于 `/home/huan/sync/fcitx5/share/rime`，文件头注释保留历史路径）。
- vendor 对象：`cn_dicts/8105.dict.yaml`、`cn_dicts/base.dict.yaml`、`en_dicts/en.dict.yaml`、`melt_eng.schema.yaml`、`melt_eng.dict.yaml`（词库目录名与 rime-ice 一致，D-12）。
- 每个 vendor 文件头部注释记录：来源文件路径、vendor 日期、是否有本地裁剪。
- vendor 时去除文件头 UTF-8 BOM：在文件前部插入注释后，BOM 会落到 YAML 流中间导致解析失败（现用工程仅 `melt_eng.schema.yaml` 带 BOM，2026-07-02 实测）。
- vendor 后即为项目内独立副本，不追随上游更新；如需同步上游，人工 diff 后决定。
- 仓库内任何文件不得引用 rime-ice 工程路径（现 `/home/huan/sync/rime-ice`；D-4 的强约束，作为首版验收项）。

## 6. 部署流程

部署采用软链接切换（D-11）：`~/.local/share/fcitx5/rime` 是指向当前激活工程配置目录的软链接。rime-lite 与 rime-ice 为平级工程，切换输入法工程 = 重指该链接，零复制，互不修改对方文件。

`tools/deploy` 行为约定：

1. `tools/deploy` 将链接指向本工程 `rime/`；`tools/deploy --to <dir>` 指向其他工程（切回 rime-ice：`--to /home/huan/sync/rime-ice`）；`--status` 查看当前激活工程；`--yes` 跳过确认。
2. 只创建 / 重指软链接；遇到真实目录一律停止，不覆盖、不删除。
3. `~/.local/share/fcitx5` 的最终形态（2026-07-02 演化完成）：真实目录；`addon`、`inputmethod`、`pinyin`、`table` 为本机真实目录；`themes` 软链接指向 `/home/huan/sync/pc_cfg/fcitx5/themes`（版本管理归 pc_cfg）；仅 `rime` 为工程切换软链接。原 `/home/huan/sync/fcitx5` 工程已于同日退役删除，历史保留在备份远端 `/mnt/backup/fcitx5`。
4. 切换后需重启 fcitx5（`fcitx5 -rd` 或注销重登）生效，脚本不代为执行。

无构建步骤；`tools/` 下现有 `deploy` 与 `userdb-candidates`（2026-07-07 随 D-15 引入）两个脚本，原计划 §4 的其余工具（`build`、`compact-lexicon`、`smoke`、`bench`）无对象，不引入。

## 7. 输入学习与多机同步

- **本机学习**：主翻译器 `enable_user_dict: true`，学习结果落在目标目录的 userdb，属运行态，不进 Git（D-1）。
- **词条晋升**：定期从 Rime 同步目录导出 userdb 文本 → 人工筛选高价值词条 → 写入 `custom_phrase.txt`（固定短语类）或目标词库（领域词 / 个人词）→ Git 提交。分析源仅限 `sync/huan_rime/rime_ice.userdb.txt` 与 `sync/huan_rime/rime_ice_huan.userdb.txt` 两份导出（D-2；rime-ice 退役前的最终导出已消费并移出工作区，git 历史 `6438887` 可查，工程本体在 `/home/huan/sync/rime-ice`）。首轮晋升已于 2026-07-07 按 D-14 完成：合并 10229 条 → 候选 143 条 → 晋升 93 条（embedded 50 / mydict 43，custom_phrase 无新增）。后续晋升按 [lexicon-sop.md](lexicon-sop.md) 执行（D-15）：分析源为现役 `pinyin.userdb` 的同步导出，候选分析用 `tools/userdb-candidates`。
- **多机同步**：Git 同步 `rime/` 与 `tools/`，新机器初始化流程为 `git clone` + `tools/deploy`；各机 userdb 独立演化，不要求实时一致（D-6）。

## 8. 扩展挂载点（非首版）

| 扩展        | 挂载方式                                                                      | 前置条件                        |
| --------- | ------------------------------------------------------------------------- | --------------------------- |
| Emoji     | vendor `opencc/emoji.json` + `emoji.txt` 至 `rime/opencc/`，filters 增加 `simplifier@emoji` | 无（数据来源已确认，D-9）              |
| ext 扩展词库  | vendor `cn_dicts/ext.dict.yaml` 至 `cn_dicts/`，追加进 `import_tables`          | 基础词库候选覆盖不足时启用               |
| 个人领域词库    | 新增 `*.dict.yaml` 追加进 `import_tables`（D-5，Rime 原生格式）                        | 已挂载（2026-07-07，D-13）      |
| AI daemon | 已挂载（2026-07-08，D-17 / D-18 / D-19），结构见 [ai-daemon.md](ai-daemon.md) | —（M2 收尾项见 [ai-daemon.md](ai-daemon.md) §8） |

## 9. 与原计划的偏离

本节已清理（2026-07-07）：对照对象「原计划」已移出工作区（git 历史 `d764656`），逐项偏离表失去参照价值；各偏离项的现行结论均由 §2 决策记录覆盖。历史内容见 git 提交 `b6a49e4` 之前的版本。

## 10. 首版完成判定

2026-07-02 已完成两轮验证：隔离 staging 目录（`rime_deployer --build` + librime 1.10.0 C API 按键探针），以及软链接切换后的真实激活路径（探针经 `~/.local/share/fcitx5/rime` 复验，双向切换复核）。fcitx5 前端交互（F4 方案选单）待重启 fcitx5 后确认。

- [x] 部署后 `nihao`、`shijie` 输出预期中文候选（实测首位：你好、世界，验证 `cn_dicts/8105` + `base` 生效；实测时目录名为 `char-lib/`，D-12 更名不影响结论）。
- [x] 输入 `hello` 出现英文候选且居首（验证 melt_eng 挂载生效）。
- [x] `custom_phrase.txt` 词条位于首位（实测 `gpio` → `GPIO`、`freertos` → `FreeRTOS`、`zkb` → `占空比`，验证 `initial_quality: 99` 排序）。
- [x] 可切换至 `melt_eng` 独立方案（API 级验证；后经 2026-07-02 调整移出 `schema_list`，不再作独立方案，git `e4aab2b`）。
- [x] 干净目录仅凭仓库文件 + `/usr/share/rime-data` 完成构建与输入（D-4 验收）。
- [x] `tools/deploy` 幂等且可双向切换（rime-lite ↔ rime-ice），全程不修改两个工程的文件与运行态。

## 11. 阶段 2/3 完成记录

2026-07-07 完成。验证方式：隔离 staging 构建（`rime_deployer --build` + librime 1.10.0 C API 按键探针，12/12 用例通过），另经 Codex 独立交叉审核（词库合并与晋升清单逐条比对零差异）。

- [x] 阶段 2（D-13）：`embedded.dict.yaml`（合并 488 + 74 条，去重 10 条冲突取高权重，552 条）与 `mydict.dict.yaml`（3 条）挂载生效；实测 `qianrushixitong` → 嵌入式系统、`zhankongbi` → 占空比、`shenfenyanzheng` → 身份验证 均居首位。
- [x] 阶段 3（D-14）：晋升 93 条（embedded 50 / mydict 43；候选 143 条中人工剔除组句残留 47 条、错词 3 条）；实测 `touchuan` → 透传、`luodang` → 落档、`furuikun` → 富芮坤 等均进前 5。
- [x] 回归不受影响：`nihao`、`hello`、`gpio`（custom_phrase）候选与首版一致；构建零 error；探针全程零写入仓库与 `~/.local/share/fcitx5/rime`。
- [x] D-4 复核：`rime/` 内无对 rime-ice 工程的运行时路径依赖（仅头部注释记录来源）。
- 已知偏差（审核发现，判定保留）：rime-ice 既有缩写码词条（如 `ARM<Tab>arm`）拼音字段为整词编码而非标准音节，属来源设计（输入 `arm` 出 `ARM` 的机制），不影响构建；mydict 的「身份验证」与 base 同词同音重复，运行时由 uniquifier 消重，按原样迁移保留。

## 12. AI 候选通路（M0/M1）完成记录

2026-07-08 完成（D-17 / D-18 / D-19 的实现验收）。验证方式：隔离 staging 构建 + librime C API 按键探针（同 §11 路径），分「daemon 缺席降级」「mock 通路」「真 API 全链路」三档；探针零写入仓库与运行目录。

- [x] 构建：staging（含 `lua/` 与 schema 挂载）`rime_deployer --build` 零 E 级日志；引擎运行零 ERROR 日志文件。
- [x] 降级（daemon 缺席）：`nihao` 候选与手感与基线一致，触发键无副作用。
- [x] mock 通路：自动预取（打字期间自主发出，无需触发键）→ 触发键注入候补（`AI候补一 ⚡` 居首、本地候选跟随）、开关关闭时不应用不外发、commit 通报到达 daemon；开关开/关每键耗时差 ≤ +0.04ms（红线预算 ≤0.1ms 达成，D-19）。修订注：初版 filter 把预取放在惰性候选流耗尽之后（正常打字不执行，被触发键显式路径掩盖），2026-07-08 当日发现并修复——预取移至头部候选收齐即发出，复验通过。
- [x] 真 API（生成式候补，D-18 演进后形态）：引擎全链路 e2e——上屏「嵌入式系统」后输入 `zhongduan`，触发得 `中断处理 ⚡ / 中断处理程序 ⚡ / 中断服务程序 ⚡`（语境理解 + 延伸预测，均非本地词库整词）；生产冒烟——上下文「下周要去上海出差」+ `gaotie` → `高铁票 / 高铁去上海 / 高铁二等座`（3.8s）。首按未命中、二按命中属 D-17 交互契约预期（spark 生成实测 1.7~7s）。
- [x] 生产接线：`lua-socket 3.1.0-1` 已系统安装；密钥配置 `~/.config/rime-candidate-daemon/config.json`（0600，不入库）；systemd 用户服务 `rime-candidate-daemon` 已 enable，负载更新随 `systemctl --user restart` 生效并复冒烟。
- [x] 真机 fcitx5 复核：用户重启 fcitx5 后，实际输入的上屏文本经 `commit_notifier` 到达 daemon（journal 可见），证明 fcitx5 进程内 Lua glue 与 socket 链路工作正常；候补注入与 D-20 两拍触发（`⚡…` 提示重绘、收割节奏）经用户真机输入抽查确认（2026-07-09）。
- [x] 模型与触发键调整（同日）：spark 生成烧 1300~2048 completion tokens/次、方差 1.7~7s → 默认换 `gpt-5.4` + `low`（冒烟 2.7~4.8s、~60 token），代码默认值 / 示例 / 本机配置同步；触发键 `Control+t` 被应用抢占 → 换 `Tab`（default.yaml 撤销 Tab 音节右移绑定），mock 回归复验通过。
- 遗留：M2 收尾项见 [ai-daemon.md](ai-daemon.md) §8。
