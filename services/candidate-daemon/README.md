# candidate-daemon — AI 智能候补 daemon

rime-lite 的 AI 生成式候补服务（决策 D-17 / D-18，设计推导见
[docs/notes/analysis/2026-07-08-ai-daemon-implementation.md](../../docs/notes/analysis/2026-07-08-ai-daemon-implementation.md)）。
Rime 侧经 `rime/lua/ai/` 以 unix socket 连接本服务；本服务根据会话上下文（近期上屏文本）
调用 OpenAI 兼容 API，生成用户想输入的完整内容（拼音整句转换 + 延伸预测，不受本地词库限制），
以 ⚡ 候补形式注入候选栏首位，选中即整段上屏。

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

字段说明：`provider`（`openai` / `mock`，后者仅链路验证用，倒序返回候选）；
`debounce_ms` 去抖窗口（连打只算稳定态）；`context_commits` / `context_chars`
控制「懂我」会话上下文（近期上屏文本）的规模；`reasoning_effort` 部分模型不接受，置 `null` 不发送。

## 启动（systemd 用户服务）

```bash
cp rime-candidate-daemon.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now rime-candidate-daemon
journalctl --user -u rime-candidate-daemon -f   # 观察日志
```

daemon 缺席时输入法自动降级为原生体验（连接失败 µs 级返回），可随时 stop / start。

## 使用

- `ai_suggest` 开关开启（默认开，F4 选单可切）：输入长度 ≥ 4 的稳定态自动预取候补；
  组词中按 `Tab` 调出（结果已预取则即时展示，AI 候补带 ⚡ 标记、居候选栏首位，
  选中即整段上屏——含延伸预测部分）。Tab 仅在组词状态被拦截，其余场景行为不变；
  组词中的音节导航改用 `Shift+Tab`（左）/ `Alt+←→`。
- 开关关闭 = trigger-only 隐私模式：不自动外发任何输入，仅按 `Tab` 时显式请求。
- 键位与参数在 `rime/pinyin.schema.yaml` 的 `ai_suggest:` 段调整。

## 协议 v1.1（NDJSON over UDS）

```text
req : {"op":"suggest","id":N,"key":"<缓存键>","pinyin":"<原始编码>","cands":["本地候选参考",…]}
      {"op":"commit","text":"<上屏文本>"}      # 会话上下文，无响应
      {"op":"ping"}                            # 健康检查
resp: {"id":N,"key":"<原样回显>","cands":["AI 候补文本",…]}   # 最优在前，≤3 条
      {"pong":true,"commits":N}
```

socket 路径：`$XDG_RUNTIME_DIR/rime-candidate-daemon.sock`（0600）。
测试钩子（环境变量）：`RIME_AI_CONFIG` 指定配置路径；`RIME_AI_SOCKET`（Lua 侧）
覆盖 socket 路径；`RIME_AI_LUASOCKET_CPATH`（Lua 侧）追加 luasocket 搜索路径。
