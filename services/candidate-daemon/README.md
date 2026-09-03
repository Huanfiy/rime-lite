# candidate-daemon — AI 智能候补 daemon

unix socket ↔ OpenAI 兼容 API 的桥，Rime 侧客户端为 `rime/lua/ai/`。行为定义、结构与交互契约见
[docs/design/ai-daemon.md](../../docs/design/ai-daemon.md)；本文只记依赖、配置、运维与协议。

## 依赖

- 系统包：`librime-plugin-lua`（漏装时 AI 通路静默消失）、`lua-socket`（librime-lua 侧 IPC）
- Python 3（仅标准库）
- 安装：`./run.sh deps` 检查，`./run.sh deps install` 或 `sudo apt install librime-plugin-lua lua-socket`

## 配置（含密钥，不入库）

```bash
./run.sh apikey init              # 从示例复制到 ~/.config/rime-candidate-daemon/config.json
./run.sh apikey set               # 写入 / 轮换密钥（不回显，0600）
./run.sh apikey                   # 查看（密钥脱敏）
```

也可手写同路径文件。`./run.sh apikey set` 支持 `--base-url` / `--model` / `--provider`；非交互环境用 `RIME_AI_API_KEY`。泄露则先在服务商侧作废旧 key，再跑 `apikey set`。

字段说明：`provider`（`openai` / `mock`，后者仅链路验证用，返回固定候补，可设 `mock_delay_ms` 模拟 API 延迟）；
`max_concurrency` 在途 API 调用上限（并发槽，默认 3）；`context_commits` / `context_chars`
控制「懂我」会话上下文（近期上屏文本）的规模；`reasoning_effort` 部分模型不接受，置 `null` 不发送；
`service_tier` 取 `priority` 使用 OpenAI Priority processing（Fast），置 `null` 不发送。
已废弃：`debounce_ms`（D-21 撤销自动预取后无去抖对象，配置中出现将被忽略）。

## 启动（systemd 用户服务）

```bash
./run.sh daemon install           # 按当前仓库绝对路径生成用户单元并 enable --now
./run.sh daemon status            # 状态
./run.sh daemon logs              # journalctl -f
```

用户单元由 `run.sh daemon install` 按当前仓库绝对路径生成（唯一来源，仓库内不存模板）。daemon 缺席时输入法自动降级为原生体验（连接失败 µs 级返回），可随时 `./run.sh daemon stop|start`。

Rime 侧键位与等待参数在 `rime/pinyin.schema.yaml` 的 `ai_suggest:` 段。

## 协议 v1.3（NDJSON over UDS）

```text
req : {"op":"suggest","id":N,"key":"<缓存键>","pinyin":"<待转换拼音(当前翻译段)>",
       "cands":["本地候选参考",…],
       "prefix":"<已选定前缀文本>"}             # 可缺省；选定首词后携带
      {"op":"commit","text":"<上屏文本>"}      # 会话上下文，无响应；作废在队请求
      {"op":"ping"}                            # 健康检查
resp: {"id":N,"key":"<原样回显>","cands":["AI 候补文本",…]}   # 最优在前，≤3 条
      {"pong":true,"commits":N}
```

所有 suggest 请求直达并发槽（同 key 在途防重）；旧版 `explicit` 字段被忽略，
v1.1 / v1.2 客户端的请求一律按显式处理。

socket 路径：`$XDG_RUNTIME_DIR/rime-candidate-daemon.sock`（0600）。
环境变量钩子：`RIME_AI_CONFIG` 指定配置路径；Lua 侧 `RIME_AI_SOCKET` 覆盖 socket 路径、
`RIME_AI_LUASOCKET_CPATH` 追加 luasocket 搜索路径、`RIME_AI_LUALIB` 覆盖 loadlib 的 liblua 路径。
