#!/usr/bin/env bash
# rime-lite 统一入口：路由到 tools/* 底层脚本，并编排 systemd / fcitx5 / 依赖检查。
# 本机运行态以本脚本 status 为准，不写进文档。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$REPO_DIR/tools/deploy"
CANDIDATES="$REPO_DIR/tools/userdb-candidates"
AI_CONFIG="$REPO_DIR/tools/ai-config"
DAEMON_PY="$REPO_DIR/services/candidate-daemon/candidate-daemon.py"
UNIT_NAME="rime-candidate-daemon"
UNIT_DST="$HOME/.config/systemd/user/${UNIT_NAME}.service"
RANKER_DIR="$REPO_DIR/services/pause-rank"
RANKER_PY="$RANKER_DIR/ranker/ranker.py"
RANKER_UNIT="rime-pause-rank"
RANKER_UNIT_DST="$HOME/.config/systemd/user/${RANKER_UNIT}.service"
ADDON_CONF="$HOME/.local/share/fcitx5/addon/pauserank.conf"
STAGING_DIR="${RIME_STAGING_DIR:-/tmp/rime-lite-staging}"
LINK="$HOME/.local/share/fcitx5/rime"

usage() {
  cat <<'EOF'
用法: ./run.sh <命令> [参数]

  status                         查看激活工程、daemon、密钥、依赖
  setup [--yes] [--install-deps] 新机器接入（检查依赖 / 部署 / daemon / 密钥）
  deploy [--to <dir>] [--yes]    激活本工程或切换到其他工程
  restart                        重启 fcitx5（fcitx5 -rd）
  verify                         隔离 staging 构建，要求零 E 级日志

  daemon install                 按当前仓库路径安装 systemd 用户单元
  daemon start|stop|restart      控制 rime-candidate-daemon
  daemon status|logs             查看服务状态 / 跟踪日志
  daemon uninstall               停用并移除用户单元（不删配置与密钥）

  ranker build                   构建停顿重排插件与打分 worker（D-30）
  ranker install                 构建 → 安装 fcitx5 插件配置 → 安装并启动打分服务
  ranker start|stop|restart      控制 rime-pause-rank
  ranker status|logs             查看服务状态 / 跟踪打分日志
  ranker uninstall               停用服务并移除插件配置（restart 后生效）

  apikey                         查看配置（密钥脱敏）
  apikey set [--base-url URL] [--model NAME] [--provider NAME]
                                 写入或轮换密钥（不回显，文件 0600），随后重启 daemon
  apikey init                    若配置不存在，从示例复制（不含真实密钥）

  candidates [userdb-candidates 参数...]
                                 晋升候选分析（只读，输出到仓库外）

  deps                           检查 AI 通路系统依赖
  deps install                   sudo apt 安装缺失依赖
EOF
}

die() { echo "错误: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
pkg_ok() { dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
unit_installed() { systemctl --user cat "${1:-$UNIT_NAME}" >/dev/null 2>&1; }

cmd_restart() {
  have fcitx5 || die "未找到 fcitx5"
  fcitx5 -rd
  echo "已请求重启 fcitx5。"
}

cmd_verify() {
  have rsync || die "未找到 rsync"
  have rime_deployer || die "未找到 rime_deployer（安装 fcitx5-rime / librime-bin）"
  mkdir -p "$STAGING_DIR"
  rsync -a --delete \
    --exclude build --exclude sync --exclude '*.userdb' \
    --exclude installation.yaml --exclude user.yaml \
    "$REPO_DIR/rime/" "$STAGING_DIR/"
  rime_deployer --build "$STAGING_DIR" /usr/share/rime-data
  echo "staging 构建完成: $STAGING_DIR"
}

missing_pkgs() {
  pkg_ok librime-plugin-lua || echo librime-plugin-lua
  pkg_ok lua-socket || echo lua-socket
  have python3 || echo python3
}

cmd_deps() {
  echo "librime-plugin-lua: $(pkg_ok librime-plugin-lua && echo ok || echo missing)"
  echo "lua-socket:         $(pkg_ok lua-socket && echo ok || echo missing)"
  echo "python3:            $(have python3 && echo ok || echo missing)"
  local missing
  missing="$(missing_pkgs | xargs)"
  [ -z "$missing" ] && return 0
  echo "缺失: $missing"
  echo "安装: sudo apt install $missing"
  return 1
}

cmd_deps_install() {
  local missing
  missing="$(missing_pkgs | xargs)"
  [ -n "$missing" ] || { echo "依赖已齐。"; return 0; }
  # shellcheck disable=SC2086
  sudo apt install $missing
}

# write_unit <单元文件> <描述> <脚本>
write_unit() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
[Unit]
Description=$2

[Service]
ExecStart=/usr/bin/python3 $3
WorkingDirectory=$REPO_DIR
Restart=on-failure
RestartSec=2
UMask=0077

[Install]
WantedBy=default.target
EOF
}

cmd_daemon() {
  case "${1:-}" in
    install)
      [ -f "$DAEMON_PY" ] || die "找不到 $DAEMON_PY"
      have python3 || die "未找到 python3"
      write_unit "$UNIT_DST" "rime-lite AI candidate daemon (D-18)" "$DAEMON_PY"
      systemctl --user daemon-reload
      systemctl --user enable --now "$UNIT_NAME"
      echo "已安装并启动 $UNIT_NAME（$UNIT_DST）"
      ;;
    start|stop|restart)
      systemctl --user "$1" "$UNIT_NAME"
      ;;
    status)
      unit_installed || die "单元未安装（$UNIT_DST 不存在）。运行: ./run.sh daemon install"
      systemctl --user --no-pager status "$UNIT_NAME" || true
      ;;
    logs)
      journalctl --user -u "$UNIT_NAME" -f
      ;;
    uninstall)
      if unit_installed; then systemctl --user disable --now "$UNIT_NAME" || true; fi
      rm -f "$UNIT_DST"
      systemctl --user daemon-reload
      echo "已移除用户单元。配置与密钥未删除。"
      ;;
    *)
      die "daemon 子命令: install|start|stop|restart|status|logs|uninstall"
      ;;
  esac
}

cmd_ranker() {
  case "${1:-}" in
    build)
      "$RANKER_DIR/build.sh"
      ;;
    install)
      have python3 || die "未找到 python3"
      "$RANKER_DIR/build.sh"
      mkdir -p "$(dirname "$ADDON_CONF")"
      cp "$RANKER_DIR/build/pauserank.conf" "$ADDON_CONF"
      write_unit "$RANKER_UNIT_DST" "rime-lite pause rerank scorer (D-30)" "$RANKER_PY"
      systemctl --user daemon-reload
      systemctl --user enable --now "$RANKER_UNIT"
      echo "已安装插件配置（$ADDON_CONF）并启动 $RANKER_UNIT。插件改动需 ./run.sh restart 生效。"
      ;;
    start|stop|restart)
      systemctl --user "$1" "$RANKER_UNIT"
      ;;
    status)
      unit_installed "$RANKER_UNIT" || die "单元未安装（$RANKER_UNIT_DST 不存在）。运行: ./run.sh ranker install"
      systemctl --user --no-pager status "$RANKER_UNIT" || true
      ;;
    logs)
      journalctl --user -u "$RANKER_UNIT" -f
      ;;
    uninstall)
      if unit_installed "$RANKER_UNIT"; then systemctl --user disable --now "$RANKER_UNIT" || true; fi
      rm -f "$RANKER_UNIT_DST" "$ADDON_CONF"
      systemctl --user daemon-reload
      echo "已移除打分服务与插件配置；./run.sh restart 后插件卸载。Lua 侧无私有键时只做一次 keycode 比较。"
      ;;
    *)
      die "ranker 子命令: build|install|start|stop|restart|status|logs|uninstall"
      ;;
  esac
}

cmd_apikey() {
  case "${1:-show}" in
    show) "$AI_CONFIG" show ;;
    init) "$AI_CONFIG" init ;;
    set)
      shift
      "$AI_CONFIG" set "$@"
      if unit_installed; then
        systemctl --user restart "$UNIT_NAME"
        echo "已重启 $UNIT_NAME。"
      else
        echo "daemon 未安装。需要时: ./run.sh daemon install"
      fi
      ;;
    *) die "apikey 子命令: show|set|init" ;;
  esac
}

cmd_status() {
  echo "== 输入方案 =="
  "$DEPLOY" --status
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "提示: $LINK 是真实目录，./run.sh deploy 会拒绝执行（D-11）。请先人工迁走或备份后再激活本工程。"
  fi
  echo
  echo "== AI daemon =="
  if unit_installed; then
    echo "unit:     $(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true) / $(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
  else
    echo "unit:     未安装"
  fi
  local sock="${XDG_RUNTIME_DIR:-/tmp}/rime-candidate-daemon.sock"
  [ -S "$sock" ] && echo "socket:   $sock" || echo "socket:   不存在"
  echo
  echo "== 停顿重排 =="
  if unit_installed "$RANKER_UNIT"; then
    echo "unit:     $(systemctl --user is-enabled "$RANKER_UNIT" 2>/dev/null || true) / $(systemctl --user is-active "$RANKER_UNIT" 2>/dev/null || true)"
  else
    echo "unit:     未安装"
  fi
  if [ -f "$ADDON_CONF" ]; then
    echo "插件:     $(sed -n 's/^Library=//p' "$ADDON_CONF")"
  else
    echo "插件:     未安装"
  fi
  local rsock="${XDG_RUNTIME_DIR:-/tmp}/rime-pause-rank/ranker.sock"
  [ -S "$rsock" ] && echo "socket:   $rsock" || echo "socket:   不存在"
  echo
  echo "== 密钥 =="
  "$AI_CONFIG" show || true
  echo
  echo "== 依赖 =="
  cmd_deps || true
}

cmd_setup() {
  local assume_yes=0 install_deps=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) assume_yes=1; shift ;;
      --install-deps) install_deps=1; shift ;;
      *) die "setup 未知参数: $1" ;;
    esac
  done

  echo "== 1/4 依赖 =="
  if ! cmd_deps; then
    if [ "$install_deps" -eq 1 ]; then cmd_deps_install; else echo "缺包装好后重试，或加 --install-deps。"; fi
  fi

  echo
  echo "== 2/4 部署输入方案 =="
  local deploy_args=()
  [ "$assume_yes" -eq 1 ] && deploy_args+=(--yes)
  "$DEPLOY" "${deploy_args[@]}" || echo "部署未完成（真实目录需人工处理，或稍后 ./run.sh deploy）。"

  echo
  echo "== 3/4 AI daemon =="
  cmd_daemon install

  echo
  echo "== 4/4 密钥 =="
  "$AI_CONFIG" init >/dev/null
  if "$AI_CONFIG" show >/dev/null; then
    echo "密钥已配置。轮换: ./run.sh apikey set"
  else
    echo "密钥未填。运行: ./run.sh apikey set"
  fi

  echo
  echo "接下来: ./run.sh restart   # 使输入方案生效"
  echo "组词中按 Tab 请求 AI 候补。daemon 缺席时自动降级为原生体验。"
  echo "停顿重排（可选，需源码构建的 llama.cpp 与模型）: ./run.sh ranker install，见 services/pause-rank/README.md"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  ""|-h|--help|help) usage ;;
  status) cmd_status ;;
  setup) cmd_setup "$@" ;;
  deploy) exec "$DEPLOY" "$@" ;;
  restart) cmd_restart ;;
  verify) cmd_verify ;;
  candidates) exec "$CANDIDATES" "$@" ;;
  deps) if [ "${1:-}" = "install" ]; then cmd_deps_install; else cmd_deps; fi ;;
  daemon) cmd_daemon "$@" ;;
  ranker) cmd_ranker "$@" ;;
  apikey) cmd_apikey "$@" ;;
  *) usage >&2; exit 2 ;;
esac
