# candidate-daemon — AI 智能候补 daemon

rime-lite 的 AI 生成式候补服务（决策 D-17 / D-18 / D-21，结构与契约见
[docs/design/ai-daemon.md](../../docs/design/ai-daemon.md)）。
Rime 侧经 `rime/lua/ai/` 以 unix socket 连接本服务；本服务根据会话上下文（近期上屏文本）
调用 OpenAI 兼容 API，生成用户想输入的完整内容（拼音整句转换 + 延伸预测，不受本地词库限制），
以 ⚡ 候补形式注入候选栏首位，选中即整段上屏。
纯触发式（D-21）：请求只在用户按触发键时发出，无自动预取，不按键零外发。

## 依赖

- 系统包：`lua-socket`（librime-lua 侧 IPC，`sudo apt install lua-socket`）
- Python 3（仅标准库）

## 配置（含密钥，不入库）

```bash
mkdir -p ~/.config/rime-candidate-daemon
cp config.example.json ~/.config/rime-candidate-daemon/config.json
chmod 600 ~/.config/rime-candidate-daemon/config.json
# 编辑 base_url / api_key / model
```

字段说明：`provider`（`openai` / `mock`，后者仅链路验证用，返回固定候补，可设 `mock_delay_ms` 模拟 API 延迟）；
`max_concurrency` 在途 API 调用上限（并发槽，默认 3）；`context_commits` / `context_chars`
控制「懂我」会话上下文（近期上屏文本）的规模；`reasoning_effort` 部分模型不接受，置 `null` 不发送。
已废弃：`debounce_ms`（D-21 撤销自动预取后无去抖对象，配置中出现将被忽略）。

## 启动（systemd 用户服务）

```bash
cp rime-candidate-daemon.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now rime-candidate-daemon
journalctl --user -u rime-candidate-daemon -f   # 观察日志
```

daemon 缺席时输入法自动降级为原生体验（连接失败 µs 级返回），可随时 stop / start。

## 使用

- 组词中按 `Tab` 调出 AI 候补（无长度门槛）——缓存命中即时展示（⚡ 标记、居候选栏首位，
  选中即整段上屏，含延伸预测部分）；未命中则亮「⚡…」提示并直达 API，
  约一个 API 周期后再按即命中，长按 `Tab` 可等结果落地自动展示。
  Tab 仅在组词状态被拦截，其余场景行为不变；组词中的音节导航改用 `Shift+Tab`（左）/ `Alt+←→`。
- 不按 `Tab` 时零请求、零外发（D-21 纯触发式，无自动预取）；上屏文本仅进本机 daemon
  内存作会话上下文，不上云。
- 键位与参数在 `rime/pinyin.schema.yaml` 的 `ai_suggest:` 段调整。

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
测试钩子（环境变量）：`RIME_AI_CONFIG` 指定配置路径；`RIME_AI_SOCKET`（Lua 侧）
覆盖 socket 路径；`RIME_AI_LUASOCKET_CPATH`（Lua 侧）追加 luasocket 搜索路径。
