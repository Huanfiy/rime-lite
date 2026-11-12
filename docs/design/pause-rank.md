# 停顿重排 — 结构与运行设计

| 项 | 内容 |
| --- | --- |
| 状态 | 现行（D-30，见 [architecture.md](architecture.md) §2） |
| 定位 | 停顿重排通路的行为、结构、契约与约束；构建、协议、参数与运维见 [services/pause-rank/README.md](../../services/pause-rank/README.md) |

## 1. 行为定义

组词中停止按键 200ms，且高亮仍在首页首项、当前段同跨度汉字候选 ≥ 2 个时，本地语言模型以「本会话上屏上文 + 已选前缀」为条件，给这些候选打分（≤ 16 个，Rime 原序），与 Rime 名次融合后选出首选：

```text
score_i = log P_LM(cand_i | 上文) − W · ln(1 + i)      # i 为 Rime 原序名次，W = 1
```

首选不是 Rime 原首选时，把它提到同跨度汉字候选的首位，其余候选相对顺序不变。⚡ AI 候补、英文、非同跨度候选的位置不变。全程在本机完成，不上云，与云端 AI 候补互不依赖（D-21 不变）。

## 2. 结构

```text
真实按键 ──► fcitx5 插件 pauserank（主循环，PreInputMethod 观察，只重置计时器）
              │ 停顿 200ms，且 IC = rime、候选 ≥ 2、首页首项、无修饰键按住
              ▼
           注入 F33 ──► pause_rank.processor：同步写候选快照 $XDG_RUNTIME_DIR/rime-pause-rank/req
              │          （同跨度汉字候选 ≤ 16 + 上文窗口 + 已选前缀）
              ▼
           转发 req ──► ranker.sock ──► ranker.py（systemd 用户服务 rime-pause-rank）
              │                           └─ 常驻 llm_score（llama.cpp，CPU），KV 按上文公共前缀复用
              │          回包 "<ver>\t<best>\t<ms>"（非阻塞连接，5ms 轮询，1.5s 超时）
              ▼
   best > 0 且期间无真实按键：写 res，注入 F34 ──► processor 校验版本 / 段身份 / 高亮
              │                                   → 记会话属性 → refresh_non_confirmed_composition
              ▼
           pause_rank.filter 按属性提升首选 → fcitx5-rime keyEvent 后 updateUI，界面与引擎同序
```

| 组件 | 位置 |
| --- | --- |
| Rime 侧 processor / filter / 常量 | `rime/lua/pause_rank/`，挂载见 `rime/pinyin.schema.yaml` |
| fcitx5 插件 | `services/pause-rank/addon/pauserank.cpp` |
| 打分服务与 worker | `services/pause-rank/ranker/` |

## 3. 交互契约

- **连续输入零等待**：插件每键只重置计时器；processor 对非私有键只比较一次 keycode；filter 的 `tags_match` 不命中时整段跳过，不迭代候选。
- **迟到结果不改写候选**：任意真实按键、修饰键释放（左 Shift 点按会切换中英）、失焦都会立即作废在途请求。回包时插件重新校验 IC 资格，Lua 侧再校验版本号、段身份（`输入串@起点-终点`）与 `selected_index == 0`。用户导航、翻页或开始选择后不重排。
- **一段只重排一次**：同一段身份已重排过就不再取快照；上屏时清空会话属性。
- **私有键不外泄**：注入走 `InputContext::keyEvent` 直达输入法，不经前端转发；未被消费也不会漏到应用。
- **上文来源**：只用当前 Rime 会话里经 Rime 上屏的文字，窗口长度保持 [80, 160) 字，起点每 80 字前移一次以便复用 KV。直接敲的英文、粘贴的内容和应用里原有的文字都看不到；不接 surrounding text。
- **数据边界**：上文与候选只经 tmpfs 文件（目录 0700）和 0600 的 unix socket 在本机流转；日志不记录上文与候选原文。

## 4. 性能、降级与红线

- **D-19**：Lua 热路径预算 ≤ 0.1ms/键不变。staging 对照实测每键增加 ≈ 2–4µs，在测量噪声内。
- **主线程阻塞**：只发生在停顿后注入私有键时。实测快照 41–162µs，应用 22–82µs。
- **降级**（全部静默，体验与原生一致）：
  - 打分服务缺席时 connect 失败，插件每分钟最多记一次日志；
  - 超时 1.5s 放弃；
  - 回包异常时丢弃；
  - 模型进程退出后，下一请求重新拉起。
- **资源**：模型 mmap 加载（Q8_0 约 640MB 文件），8 线程 CPU 推理；只在停顿时计算。

## 5. 关键实现约束（维护前必读）

- **计时精度**：sd-event 的精度参数传 0 时会退回 250ms 合并窗口，插件必须显式设为 1ms（`kAccuracyUs`），否则停顿到生效会多出约 200ms。
- **计时器生命周期**：两个计时器常驻，用 `setTime` + `setOneShot` 重新装填，不在自身回调里销毁。
- **刷新路径**：processor 处理 F34 时调用 `refresh_non_confirmed_composition`；fcitx5-rime 在 keyEvent 后无条件 `updateUI`，界面与引擎候选顺序因此一致。不要改成只刷新界面。
- **挂载顺序**：processor 居首，私有键不会被其他 processor 截获。filter 在 `ai.suggest` 之前，保证 ⚡ 候补仍居首、`uniquifier` 仍在最后。
- **惰性候选流**：filter 只缓冲到命中目标为止，或扫满 60 个（`MAX_SCAN`）后原样放行，不拉全量候选。
- **模块缓存**：librime-lua 会缓存模块，改 Lua 后须重启 fcitx5。
- **插件路径**：addon 配置的 `Library=` 是构建时的绝对路径，仓库移动后须重新 `./run.sh ranker install`。

## 6. 已知问题与演进点

- **同跨度候选只有 2 个时，Rime 先验只有 ln2，LM 容易推翻强短语**。例如上文是驱动语境时，`nihao` 被改成「拟好」。试用期间 2 候选请求有 104 次，改动 10 次。可选方向：用 `cand.quality` 代替名次作先验、提高 `MARGIN`，或要求至少 3 个候选。
- **候选在最后一次按键约 0.25s 后当面变动**。恰好在这一刻按空格时，上屏的可能与用户看到的不一致。
- **冷请求较慢**：上文窗口前移（每 80 字一次）或切换会话时要整段重算，冷请求约 140–170ms。p95 打分耗时 106ms，高于早期设定的 80ms 起始目标，实测见 [local-ranker-eval.md](../notes/local-ranker-eval.md)。
- **未覆盖**：持久学习、领域适应、真实文本上下文（原建议架构 `docs/plans/local-ranker.md` 已移出工作区，git 历史 `81c0f8b` 可查）。
