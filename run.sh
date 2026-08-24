#!/usr/bin/env bash
# rime-lite 统一入口：部署、验证、daemon、密钥。
# 底层实现仍是 tools/deploy 与 tools/userdb-candidates；本机状态以本脚本 status 为准。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$REPO_DIR/tools/deploy"
CANDIDATES="$REPO_DIR/tools/userdb-candidates"
DAEMON_PY="$REPO_DIR/services/candidate-daemon/candidate-daemon.py"
UNIT_NAME="rime-candidate-daemon"
UNIT_DST="$HOME/.config/systemd/user/${UNIT_NAME}.service"
CONFIG_DIR="$HOME/.config/rime-candidate-daemon"
CONFIG_FILE="$CONFIG_DIR/config.json"
EXAMPLE_CFG="$REPO_DIR/services/candidate-daemon/config.example.json"
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

  apikey                         查看配置（密钥脱敏）
  apikey set [--base-url URL] [--model NAME] [--provider NAME]
                                 写入或轮换密钥（不回显，文件 0600）
  apikey init                    若配置不存在，从示例复制（不含真实密钥）

  candidates [userdb-candidates 参数...]
                                 晋升候选分析（只读，输出到仓库外）

  deps                           检查 AI 通路系统依赖
  deps install                   sudo apt 安装缺失依赖

本机运行态不要写进文档，以本命令输出为准。
EOF
}

die() { echo "错误: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

pkg_ok() {
  have dpkg-query && dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

mask_key() {
  local k="$1"
  local n=${#k}
  if [ -z "$k" ] || [ "$k" = "REPLACE_ME" ]; then
    echo "<未配置>"
  elif [ "$n" -le 8 ]; then
    echo "****"
  else
    echo "${k:0:4}…${k: -4}"
  fi
}

json_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],"") or "")' "$1" "$2"
}

perm_of() {
  if [ -e "$1" ]; then
    python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
  else
    echo "<无>"
  fi
}

unit_installed() {
  systemctl --user cat "$UNIT_NAME" >/dev/null 2>&1
}

cmd_deploy() {
  exec "$DEPLOY" "$@"
}

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

cmd_candidates() {
  exec "$CANDIDATES" "$@"
}

print_deps() {
  echo "librime-plugin-lua: $(pkg_ok librime-plugin-lua && echo ok || echo missing)"
  echo "lua-socket:         $(pkg_ok lua-socket && echo ok || echo missing)"
  echo "python3:            $(have python3 && echo ok || echo missing)"
}

missing_pkgs() {
  pkg_ok librime-plugin-lua || echo librime-plugin-lua
  pkg_ok lua-socket || echo lua-socket
  have python3 || echo python3
}

cmd_deps() {
  print_deps
  local missing
  missing="$(missing_pkgs | tr '\n' ' ')"
  missing="${missing%% }"
  if [ -n "$missing" ]; then
    echo "缺失: $missing"
    echo "安装: sudo apt install $missing"
    return 1
  fi
}

cmd_deps_install() {
  local missing
  missing="$(missing_pkgs | tr '\n' ' ')"
  missing="${missing%% }"
  [ -n "$missing" ] || { echo "依赖已齐。"; return 0; }
  # shellcheck disable=SC2086
  sudo apt install $missing
}

write_unit() {
  mkdir -p "$(dirname "$UNIT_DST")"
  cat > "$UNIT_DST" <<EOF
[Unit]
Description=rime-lite AI candidate daemon (D-18)

[Service]
ExecStart=/usr/bin/python3 $DAEMON_PY
WorkingDirectory=$REPO_DIR
Restart=on-failure
RestartSec=2
UMask=0077

[Install]
WantedBy=default.target
EOF
}

cmd_daemon() {
  local action="${1:-}"
  case "$action" in
    install)
      [ -f "$DAEMON_PY" ] || die "找不到 $DAEMON_PY"
      have python3 || die "未找到 python3"
      write_unit
      systemctl --user daemon-reload
      systemctl --user enable --now "$UNIT_NAME"
      echo "已安装并启动 $UNIT_NAME"
      echo "单元: $UNIT_DST"
      echo "ExecStart=/usr/bin/python3 $DAEMON_PY"
      ;;
    start|stop|restart)
      systemctl --user "$action" "$UNIT_NAME"
      ;;
    status)
      if unit_installed; then
        systemctl --user --no-pager status "$UNIT_NAME" || true
      else
        echo "单元未安装（$UNIT_DST 不存在）。运行: ./run.sh daemon install"
        return 1
      fi
      ;;
    logs)
      journalctl --user -u "$UNIT_NAME" -f
      ;;
    uninstall)
      if unit_installed; then
        systemctl --user disable --now "$UNIT_NAME" || true
      fi
      rm -f "$UNIT_DST"
      systemctl --user daemon-reload
      echo "已移除用户单元。配置与密钥未删除: $CONFIG_FILE"
      ;;
    *)
      die "daemon 子命令: install|start|stop|restart|status|logs|uninstall"
      ;;
  esac
}

cmd_apikey_show() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置不存在: $CONFIG_FILE"
    echo "初始化: ./run.sh apikey init   然后  ./run.sh apikey set"
    return 1
  fi
  echo "路径:     $CONFIG_FILE"
  echo "权限:     $(perm_of "$CONFIG_FILE")"
  echo "provider: $(json_get "$CONFIG_FILE" provider)"
  echo "base_url: $(json_get "$CONFIG_FILE" base_url)"
  echo "model:    $(json_get "$CONFIG_FILE" model)"
  echo "api_key:  $(mask_key "$(json_get "$CONFIG_FILE" api_key)")"
  if [ "$(perm_of "$CONFIG_FILE")" != "0o600" ]; then
    echo "警告: 权限不是 0600，运行: chmod 600 $CONFIG_FILE"
  fi
}

cmd_apikey_init() {
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ]; then
    echo "已存在: $CONFIG_FILE （未覆盖）"
  else
    cp "$EXAMPLE_CFG" "$CONFIG_FILE"
    echo "已从示例复制: $CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE"
  echo "接下来: ./run.sh apikey set"
}

cmd_apikey_set() {
  local base_url="" model="" provider=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-url) base_url="${2:?}"; shift 2 ;;
      --model)    model="${2:?}"; shift 2 ;;
      --provider) provider="${2:?}"; shift 2 ;;
      *) die "未知参数: $1（支持 --base-url / --model / --provider）" ;;
    esac
  done
  [ -f "$CONFIG_FILE" ] || { mkdir -p "$CONFIG_DIR"; cp "$EXAMPLE_CFG" "$CONFIG_FILE"; }
  local key="${RIME_AI_API_KEY:-}"
  if [ -z "$key" ]; then
    if [ -t 0 ]; then
      read -r -s -p "API key（输入不回显）: " key
      echo
    else
      die "非交互环境请设置 RIME_AI_API_KEY，或在终端运行本命令"
    fi
  fi
  [ -n "$key" ] || die "密钥为空"
  # 经环境变量交给 python，避免进入 argv / shell 历史
  RIME_AI_API_KEY_STDIN="$key" python3 - "$CONFIG_FILE" "$base_url" "$model" "$provider" <<'PY'
import json, os, sys
path, base_url, model, provider = sys.argv[1:5]
key = os.environ["RIME_AI_API_KEY_STDIN"]
cfg = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
cfg["api_key"] = key
if base_url:
    cfg["base_url"] = base_url
if model:
    cfg["model"] = model
if provider:
    cfg["provider"] = provider
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
  echo "已写入 $CONFIG_FILE（0600）。请同时在服务商侧作废旧 key。"
  echo "密钥不会出现在仓库或本输出中。"
  if unit_installed; then
    systemctl --user restart "$UNIT_NAME"
    echo "已重启 $UNIT_NAME。"
  else
    echo "daemon 未安装。需要时: ./run.sh daemon install"
  fi
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
    echo "unit文件: $UNIT_DST"
  else
    echo "unit:     未安装"
  fi
  local sock="${XDG_RUNTIME_DIR:-/tmp}/rime-candidate-daemon.sock"
  if [ -S "$sock" ]; then
    echo "socket:   $sock"
  else
    echo "socket:   不存在"
  fi
  echo
  echo "== 密钥 =="
  if [ -f "$CONFIG_FILE" ]; then
    echo "config:   $CONFIG_FILE ($(perm_of "$CONFIG_FILE"))"
    echo "provider: $(json_get "$CONFIG_FILE" provider)"
    echo "base_url: $(json_get "$CONFIG_FILE" base_url)"
    echo "model:    $(json_get "$CONFIG_FILE" model)"
    echo "api_key:  $(mask_key "$(json_get "$CONFIG_FILE" api_key)")"
  else
    echo "config:   不存在（./run.sh apikey init && ./run.sh apikey set）"
  fi
  echo
  echo "== 依赖 =="
  print_deps || true
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
    if [ "$install_deps" -eq 1 ]; then
      cmd_deps_install
    else
      echo "缺包装好后重试，或加 --install-deps。"
    fi
  fi

  echo
  echo "== 2/4 部署输入方案 =="
  if [ "$assume_yes" -eq 1 ]; then
    "$DEPLOY" --yes || echo "部署未完成（真实目录需人工处理，或稍后 ./run.sh deploy）。"
  else
    "$DEPLOY" || echo "部署未完成（真实目录需人工处理，或稍后 ./run.sh deploy）。"
  fi

  echo
  echo "== 3/4 AI daemon =="
  cmd_daemon install

  echo
  echo "== 4/4 密钥 =="
  if [ -f "$CONFIG_FILE" ]; then
    local k
    k="$(json_get "$CONFIG_FILE" api_key)"
    if [ -n "$k" ] && [ "$k" != "REPLACE_ME" ]; then
      echo "已有密钥 $(mask_key "$k")。轮换: ./run.sh apikey set"
    else
      echo "配置在但密钥未填。运行: ./run.sh apikey set"
    fi
  else
    cmd_apikey_init
    echo "配置密钥: ./run.sh apikey set"
  fi

  echo
  echo "接下来: ./run.sh restart   # 使输入方案生效"
  echo "组词中按 Tab 请求 AI 候补。daemon 缺席时自动降级为原生体验。"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  ""|-h|--help|help) usage ;;
  status) cmd_status ;;
  setup) cmd_setup "$@" ;;
  deploy) cmd_deploy "$@" ;;
  restart) cmd_restart ;;
  verify) cmd_verify ;;
  candidates) cmd_candidates "$@" ;;
  deps)
    if [ "${1:-}" = "install" ]; then cmd_deps_install; else cmd_deps; fi
    ;;
  daemon) cmd_daemon "$@" ;;
  apikey)
    case "${1:-show}" in
      show|"") cmd_apikey_show ;;
      init) cmd_apikey_init ;;
      set) shift; cmd_apikey_set "$@" ;;
      *) die "apikey 子命令: show|set|init" ;;
    esac
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
