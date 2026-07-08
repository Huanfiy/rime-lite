#!/usr/bin/env python3
"""rime-lite AI 候选 daemon（D-17 / D-18）。

职责：unix socket ↔ OpenAI 兼容 API 的桥；工作负载为**生成式智能候补**——
根据会话上下文（近期上屏文本）预测用户想输入的完整内容（拼音整句转换 + 延伸预测，
不受本地词库限制）；请求去抖合并（连打只算稳定态）；API key 托管（配置文件，不入库）。

协议 v1.1（NDJSON over UDS，与 rime/lua/ai/glue.lua 对应）：
  req : {"op":"suggest","id":N,"key":"<缓存键>","pinyin":"<原始编码>","cands":["本地候选参考",…]}
        {"op":"commit","text":"<上屏文本>"}
        {"op":"ping"}
  resp: {"id":N,"key":"<原样回显>","cands":["AI 候补文本",…]}   # 最优在前，≤3 条
        {"pong":true,"commits":N}

仅用 Python 标准库；配置见 config.example.json 与 README.md。
"""
import asyncio
import collections
import http.client
import json
import os
import re
import socket as socket_mod
import sys
import threading
import time
import urllib.parse

DEFAULTS = {
    "socket_path": None,          # 默认 $XDG_RUNTIME_DIR/rime-candidate-daemon.sock
    "provider": "openai",         # openai | mock（mock 供链路验证：倒序返回候选）
    "base_url": "",
    "api_key": "",
    "model": "gpt-5.4",
    "reasoning_effort": "low",    # 部分模型不接受该参数（如 spark），置 null 则不发送
    "debounce_ms": 300,           # 去抖：仅输入稳定态触发 API
    "context_commits": 6,         # 会话上下文保留的上屏条数
    "context_chars": 80,          # 送入 prompt 的上下文尾部长度
    "request_timeout_s": 20,
}

SYSTEM_PROMPT = (
    "你是拼音输入法的智能候补引擎。根据上文语境预测用户想输入的完整内容。规则:"
    "输出1到3行,每行一个候补,最优在前;"
    "每个候补必须以给定拼音的中文转换开头,并尽量延伸预测用户接下来要输入的内容(延伸不超过10字);"
    "可参考本地候选理解拼音,但不受其限制;只输出候补文本,不加序号、标点解释。"
)

_commit_total = 0  # 跨连接统计，仅供 ping 诊断


def log(*args):
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


def load_config():
    path = os.environ.get(
        "RIME_AI_CONFIG",
        os.path.expanduser("~/.config/rime-candidate-daemon/config.json"),
    )
    cfg = dict(DEFAULTS)
    try:
        with open(path) as f:
            cfg.update(json.load(f))
        log(f"config loaded: {path} (provider={cfg['provider']} model={cfg['model']})")
    except FileNotFoundError:
        log(f"config not found: {path}, using defaults (provider={cfg['provider']})")
    if not cfg["socket_path"]:
        cfg["socket_path"] = os.path.join(
            os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "rime-candidate-daemon.sock"
        )
    return cfg


class OpenAIClient:
    """持久连接的 OpenAI 兼容客户端（TLS 握手摊销，实测 0.33s/次）。"""

    def __init__(self, cfg):
        u = urllib.parse.urlparse(cfg["base_url"])
        self.host = u.netloc
        self.prefix = u.path.rstrip("/")
        self.cfg = cfg
        self.conn = None
        self.lock = threading.Lock()

    def _request(self, body):
        if self.conn is None:
            self.conn = http.client.HTTPSConnection(
                self.host, timeout=self.cfg["request_timeout_s"]
            )
        self.conn.request(
            "POST",
            self.prefix + "/chat/completions",
            body=body,
            headers={
                "Authorization": "Bearer " + self.cfg["api_key"],
                "Content-Type": "application/json",
            },
        )
        resp = self.conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {data[:200]!r}")
        return json.loads(data)

    def suggest(self, pinyin, cands, context_text):
        payload = {
            "model": self.cfg["model"],
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": (
                        f"上文:{context_text or '(无)'}\n"
                        f"拼音:{pinyin}\n"
                        f"本地候选参考:{' '.join(cands) or '(无)'}"
                    ),
                },
            ],
            "temperature": 0,
        }
        if self.cfg.get("reasoning_effort"):
            payload["reasoning_effort"] = self.cfg["reasoning_effort"]
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        with self.lock:
            try:
                data = self._request(body)
            except Exception:
                # 连接层故障重连重试一次（服务端关闭空闲连接是常态）
                try:
                    if self.conn:
                        self.conn.close()
                finally:
                    self.conn = None
                data = self._request(body)
        content = data["choices"][0]["message"]["content"]
        texts = []
        for line in content.splitlines():
            line = re.sub(r"^\s*(?:\d+[.、)]|[-*•·])\s*", "", line).strip()
            # 丢弃空行、复读拼音、超长输出（候选栏不适合装长文）
            if line and line != pinyin and len(line) <= 24 and line not in texts:
                texts.append(line)
        usage = data.get("usage", {})
        return texts[:3], usage


async def handle_conn(reader, writer, cfg, client):
    global _commit_total
    peer_ctx = collections.deque(maxlen=cfg["context_commits"])
    state = {"latest_id": None, "api_lock": asyncio.Lock()}
    debounce = cfg["debounce_ms"] / 1000.0
    loop = asyncio.get_running_loop()

    async def do_suggest(obj):
        state["latest_id"] = obj["id"]
        if debounce > 0:
            await asyncio.sleep(debounce)
        if state["latest_id"] != obj["id"]:
            return  # 去抖窗口内被更新输入取代
        async with state["api_lock"]:
            if state["latest_id"] != obj["id"]:
                return
            local_cands = obj.get("cands") or []
            t0 = time.time()
            if cfg["provider"] == "mock":
                texts = ["AI候补一", "AI候补二"]
                note = "mock"
            else:
                ctx_text = "".join(peer_ctx)[-cfg["context_chars"]:]
                try:
                    texts, usage = await loop.run_in_executor(
                        None, client.suggest, obj.get("pinyin", ""), local_cands, ctx_text
                    )
                    note = f"tokens={usage.get('prompt_tokens')}+{usage.get('completion_tokens')}"
                except Exception as e:
                    log(f"suggest id={obj['id']} API error: {e!r}")
                    return
            if not texts:
                log(f"suggest id={obj['id']} empty result, dropped")
                return
            resp = {"id": obj["id"], "key": obj["key"], "cands": texts}
            try:
                writer.write((json.dumps(resp, ensure_ascii=False) + "\n").encode())
                await writer.drain()
            except (ConnectionError, RuntimeError):
                # 客户端已断开（fcitx5 重启等），丢弃结果即可
                log(f"suggest id={obj['id']} client gone, result dropped")
                return
            log(
                f"suggest id={obj['id']} pinyin={obj.get('pinyin', '')!r} "
                f"{(time.time() - t0) * 1000:.0f}ms cands={texts!r} {note}"
            )

    log("client connected")
    try:
        async for line in reader:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            op = obj.get("op")
            if op == "suggest" and "id" in obj and "key" in obj:
                asyncio.create_task(do_suggest(obj))
            elif op == "commit" and obj.get("text"):
                peer_ctx.append(str(obj["text"]))
                _commit_total += 1
                log(f"commit {obj['text']!r} (ctx={len(peer_ctx)})")
            elif op == "ping":
                writer.write(
                    (json.dumps({"pong": True, "commits": _commit_total}) + "\n").encode()
                )
                await writer.drain()
    except (ConnectionResetError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()
        log("client disconnected")


def claim_socket(path):
    """单实例守护：能连上说明已有实例在跑；连不上则清掉陈旧 socket 文件。"""
    if os.path.exists(path):
        probe = socket_mod.socket(socket_mod.AF_UNIX, socket_mod.SOCK_STREAM)
        probe.settimeout(0.5)
        try:
            probe.connect(path)
            probe.close()
            log(f"another instance is serving {path}, exit")
            sys.exit(1)
        except OSError:
            os.unlink(path)


async def main():
    cfg = load_config()
    if cfg["provider"] == "openai" and not (cfg["base_url"] and cfg["api_key"]):
        log("FATAL: provider=openai 需要 base_url 与 api_key（见 config.example.json）")
        sys.exit(1)
    path = cfg["socket_path"]
    claim_socket(path)
    client = OpenAIClient(cfg) if cfg["provider"] == "openai" else None
    server = await asyncio.start_unix_server(
        lambda r, w: handle_conn(r, w, cfg, client), path=path
    )
    os.chmod(path, 0o600)
    log(f"serving on {path}")
    try:
        async with server:
            await server.serve_forever()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
