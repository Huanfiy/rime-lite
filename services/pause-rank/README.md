# pause-rank — 停顿重排插件与本地打分服务

fcitx5 插件 + 本地 LM 打分服务，Rime 侧为 `rime/lua/pause_rank/`。行为定义、结构与交互契约见
[docs/design/pause-rank.md](../../docs/design/pause-rank.md)；本文只记依赖、构建、参数、协议与运维。

## 依赖

| 项 | 要求 | 本机验证版本 |
| --- | --- | --- |
| fcitx5 开发头 | `libfcitx5core-dev`（pkg-config `Fcitx5Core`） | 5.1.7 |
| 编译器 | g++，C++17 | 13.2 |
| llama.cpp | 源码树，按 CPU 构建出 `build/bin/libllama.so`；路径取 `LLAMA_DIR`，默认 `~/tools/llama.cpp` | `7ab4ee7`（2026-09-22） |
| 模型 | GGUF，默认 `~/tools/aimodels/Qwen3-0.6B-Base-Q8_0.gguf` | Qwen3-0.6B-Base（Apache-2.0）：官方 HF 权重经 `convert_hf_to_gguf.py --outtype f16`，再 `llama-quantize … Q8_0` |
| Python | 3，仅标准库 | — |

模型与构建产物都不入库：`build/` 由 `.gitignore` 隔离。

## 构建与安装

```bash
./run.sh ranker install    # build.sh 构建 → 复制插件配置到 ~/.local/share/fcitx5/addon/ → 安装并启动用户单元
./run.sh restart           # 插件随 fcitx5 重启加载；Rime 侧挂载随 schema 部署生效
./run.sh ranker uninstall  # 停用服务、移除插件配置；restart 后插件卸载
```

`build.sh` 产出到 `build/` 的文件：

- `libpauserank.so`：fcitx5 插件；
- `pauserank.conf`：插件配置，`Library=` 为绝对路径；
- `llm_score`：打分 worker，rpath 指向 `$LLAMA_DIR/build/bin`。

用户单元 `rime-pause-rank` 由 `run.sh` 按当前仓库绝对路径生成（唯一来源，仓库内不存模板）。仓库移动或升级 llama.cpp 后，重新执行 `./run.sh ranker install`。

## 参数

| 参数 | 位置 | 默认 |
| --- | --- | --- |
| 停顿判定 / 收包轮询 / 超时 | `addon/pauserank.cpp` 的 `kPauseUs` / `kPollUs` / `kTimeoutUs` | 200ms / 5ms / 1.5s |
| 扫描深度 / 送打分候选上限 | `rime/lua/pause_rank/common.lua` 的 `MAX_SCAN` / `MAX_CANDS` | 60 / 16 |
| 上文窗口步长 | `rime/lua/pause_rank/processor.lua` 的 `WIN` | 80 字 |
| 模型路径 | 环境变量 `RIME_PAUSE_RANK_MODEL` | 见依赖表 |
| 推理线程 | `RIME_PAUSE_RANK_THREADS` | 8 |
| 名次先验权重 W | `RIME_PAUSE_RANK_W` | 1（P0 测评文档集最优；新闻集最优为 2） |
| 改首选所需融合分差 | `RIME_PAUSE_RANK_MARGIN` | 0 |

环境变量用 `systemctl --user edit rime-pause-rank` 写入 `[Service]` 段的 `Environment=`，再 `./run.sh ranker restart`。改插件常量后需 `./run.sh ranker build` + `./run.sh restart`；改 Lua 后需 `./run.sh restart`。

## 协议

运行时目录：`$XDG_RUNTIME_DIR/rime-pause-rank/`（tmpfs，0700）。

| 步骤 | 载体 | 内容 |
| --- | --- | --- |
| 快照 | 插件注入 `F33`（0xFFDE）→ processor 原子写 `req` | `{"ver":N,"ctx":"<上文窗口+已选前缀>","cands":["Rime 原序同跨度汉字候选",…]}` |
| 打分 | 插件把 `req` 原样转发到 `ranker.sock`（0600），一请求一连接 | 回一行 `<ver>\t<best>\t<lm_ms>`；`best` 为 `cands` 下标，0 = 维持 |
| 应用 | `best > 0` 时插件写 `res`（回包原文）并注入 `F34`（0xFFDF） | processor 校验后写会话属性 `pause_rank_key` / `pause_rank_text`，filter 读取 |

`ver` 为 processor 会话内递增序号。插件作废请求时直接关闭连接，服务端记 `cancelled`。

## 运维

- 服务：`./run.sh ranker status|restart|logs`。
  - journal 每条请求记一行：`ver`、打分耗时、上文重算 token 数（`head_dec`）、候选数、`best`；不记原文。
- 插件日志：`$XDG_RUNTIME_DIR/rime-pause-rank/plugin.log`，超过 1MB 时清空重写。
  - 每次停顿记一行：`keep` / `apply` / `drop`，以及停顿到回包或生效的耗时。
  - 连不上服务、超时等异常也记在这里，是「插件是否在工作」的地面真相。
- 真机测试：
  - 用 DBus 建测试 IC 时，`display` 须是不匹配任何焦点组的值（如 `pauserank-test:`）；否则 DBus 前端处理按键时会抢走焦点，候选面板会出现在用户屏幕上。
  - 测试只敲拼音后按 Esc，不要上屏，避免写入运行中的 userdb。
