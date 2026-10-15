#!/usr/bin/env bash
# 构建停顿重排（D-30）的原生组件到 build/（.gitignore 隔离），由 ./run.sh ranker build|install 调用：
#   libpauserank.so + pauserank.conf  fcitx5 插件；conf 的 Library 用绝对路径（fcitx5 5.1.7 StandardPath 支持）
#   llm_score                         打分 worker，链接源码构建的 llama.cpp（rpath 指向其 build/bin）
# llama.cpp 源码树取 LLAMA_DIR（默认 ~/tools/llama.cpp），须已构建出 build/bin/libllama.so。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
L="${LLAMA_DIR:-$HOME/tools/llama.cpp}"

pkg-config --exists Fcitx5Core || { echo "错误: 缺少 Fcitx5Core 开发包（libfcitx5core-dev）" >&2; exit 1; }
[ -f "$L/build/bin/libllama.so" ] || { echo "错误: 未找到 $L/build/bin/libllama.so（设 LLAMA_DIR 或先构建 llama.cpp）" >&2; exit 1; }
mkdir -p "$OUT"

# shellcheck disable=SC2046
g++ -O2 -Wall -Wextra -fPIC -shared -std=c++17 $(pkg-config --cflags Fcitx5Core) \
  "$HERE/addon/pauserank.cpp" -o "$OUT/libpauserank.so" $(pkg-config --libs Fcitx5Core)

cat > "$OUT/pauserank.conf" <<CONF
[Addon]
Name=Pause Rank
Category=Module
Version=1.0
Library=$OUT/libpauserank
Type=SharedLibrary
OnDemand=False
Configurable=False

[Addon/Dependencies]
0=core:5.1.0
CONF

g++ -O2 -Wall -std=c++17 -I"$L/include" -I"$L/ggml/include" -I"$L/vendor" \
  "$HERE/ranker/llm_score.cpp" -L"$L/build/bin" -lllama -lggml -lggml-base \
  -Wl,-rpath,"$L/build/bin" -o "$OUT/llm_score"

echo "已构建: $OUT/{libpauserank.so,pauserank.conf,llm_score}"
