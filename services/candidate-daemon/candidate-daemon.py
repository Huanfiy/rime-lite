#!/usr/bin/env python3
"""rime-lite AI 候选 daemon（D-17 / D-18 / D-21 / D-22）。

职责：unix socket ↔ OpenAI 兼容 API 的桥；工作负载为**生成式智能候补**——
根据会话上下文（近期上屏文本）预测用户想输入的完整内容（拼音整句转换 + 延伸预测，
不受本地词库限制）；API key 托管（配置文件，不入库）。

协议 v1.3（NDJSON over UDS，与 rime/lua/ai/glue.lua 对应）：
  req : {"op":"suggest","id":N,"key":"<缓存键>","pinyin":"<待转换拼音(当前翻译段)>",
         "cands":["本地候选参考",…],"prefix":"<已选定前缀文本,可缺省>"}
        {"op":"commit","text":"<上屏文本>"}
        {"op":"ping"}
  resp: {"id":N,"key":"<原样回显>","cands":["AI 候补文本",…]}   # 最优在前，≤3 条
        {"pong":true,"commits":N}
  旧版 explicit 字段被忽略——v1.3 起所有请求都由触发键显式产生（D-21），
  v1.1 / v1.2 客户端的请求一律按显式处理。

调度模型（2026-07-09 纯触发式改造，D-21，取代 D-20 的 auto/explicit 双路径）：
  请求仅由触发键产生 → 并发槽（同 key 在途防重）→ API，端到端 = API 净耗时；
  上屏（commit）作废仍在等并发槽的请求——组词态已变、结果注定失配；
  已在途的 API 调用不中断（token 已花，回包由客户端按 key 失配丢弃）。

仅用 Python 标准库；配置见 config.example.json 与 README.md。
"""
import asyncio
import collections
import http.client
import json
import os
import queue
import re
import socket as socket_mod
import sys
import time
import urllib.parse

DEFAULTS = {
    "socket_path": None,          # 默认 $XDG_RUNTIME_DIR/rime-candidate-daemon.sock
    "provider": "openai",         # openai | mock（mock 供链路验证：返回固定候补）
    "base_url": "",
    "api_key": "",
    "model": "gpt-5.6-sol",
    "reasoning_effort": "low",    # 当前中转的 GPT-5.6 最低可用推理档；置 null 则不发送
    "service_tier": "priority",   # OpenAI Fast：Priority processing；置 null 则不发送
    "max_concurrency": 3,         # 在途 API 调用上限（并发槽）
    "context_commits": 6,         # 会话上下文保留的上屏条数
    "context_chars": 80,          # 送入 prompt 的上下文尾部长度
    "request_timeout_s": 20,
    "mock_delay_ms": 0,           # mock 模拟 API 延迟（仅 provider=mock，供并发/取消链路验证）
}
# 已废弃配置（D-21 撤销自动预取后无消费方）：debounce_ms——配置文件中出现将被忽略。

# 候补口径单点（ai-daemon.md §8，D-22）：严格不超过 100 字；保留领域消歧、
# 机械候选抗锚定、首行纯转换、延伸边界与已选前缀约束。
SYSTEM_PROMPT = (
    "嵌入式拼音输入法：依上文完整转写，优先电子/半导体/编程术语，"
    "如fushanjingtiguan=浮栅晶体管。本地机械转换仅供切分。"
    "首行只转写，后两行可续写≤10字。仅输出1～3行，不重复已选前缀。"
)
assert len(SYSTEM_PROMPT) <= 100

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
    """OpenAI 兼容客户端；小型连接池支撑并发调用（TLS 握手摊销，实测 0.33s/次）。"""

    def __init__(self, cfg):
        u = urllib.parse.urlparse(cfg["base_url"])
        self.host = u.netloc
        self.prefix = u.path.rstrip("/")
        self.cfg = cfg
        self.pool = queue.LifoQueue()  # 空闲连接池；规模天然 ≤ max_concurrency

    def _new_conn(self):
        return http.client.HTTPSConnection(
            self.host, timeout=self.cfg["request_timeout_s"]
        )

    def _request(self, conn, body):
        conn.request(
            "POST",
            self.prefix + "/chat/completions",
            body=body,
            headers={
                "Authorization": "Bearer " + self.cfg["api_key"],
                "Content-Type": "application/json",
            },
        )
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {data[:200]!r}")
        return json.loads(data)

    def suggest(self, pinyin, cands, context_text, sel_prefix=""):
        lines = [f"上文:{context_text or '(无)'}"]
        if sel_prefix:
            lines.append(f"已选前缀:{sel_prefix}")
        lines.append(f"拼音:{pinyin}")
        lines.append(f"本地机械转换:{' '.join(cands) or '(无)'}")
        payload = {
            "model": self.cfg["model"],
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": "\n".join(lines)},
            ],
            "temperature": 0,
        }
        if self.cfg.get("reasoning_effort"):
            payload["reasoning_effort"] = self.cfg["reasoning_effort"]
        if self.cfg.get("service_tier"):
            payload["service_tier"] = self.cfg["service_tier"]
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            conn = self.pool.get_nowait()
        except queue.Empty:
            conn = self._new_conn()
        try:
            data = self._request(conn, body)
        except Exception:
            # 连接层故障换新连接重试一次（服务端关闭空闲连接是常态）
            try:
                conn.close()
            except Exception:
                pass
            conn = self._new_conn()
            try:
                data = self._request(conn, body)
            except Exception:
                try:
                    conn.close()
                except Exception:
                    pass
                raise
        self.pool.put(conn)
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
    state = {
        "gen": 0,             # 上屏代数：commit 后组词态已变，等槽中的请求全部作废
        "inflight": set(),    # 在途 API 的缓存键（同 key 防重）
        "sem": asyncio.Semaphore(max(1, int(cfg["max_concurrency"]))),
    }
    loop = asyncio.get_running_loop()

    async def do_suggest(obj):
        rid, key = obj["id"], obj["key"]
        pinyin = obj.get("pinyin", "")
        gen0 = state["gen"]
        if key in state["inflight"]:
            return  # 同 key 已在途（重复触发时由在途者供餐）
        state["inflight"].add(key)
        try:
            async with state["sem"]:
                if state["gen"] != gen0:
                    return  # 排队期间已上屏：组词态已变，在队请求一律作废
                local_cands = obj.get("cands") or []
                t0 = time.time()
                if cfg["provider"] == "mock":
                    if cfg["mock_delay_ms"] > 0:
                        await asyncio.sleep(cfg["mock_delay_ms"] / 1000.0)
                    texts = ["AI候补一", "AI候补二"]
                    note = "mock"
                else:
                    ctx_text = "".join(peer_ctx)[-cfg["context_chars"]:]
                    try:
                        texts, usage = await loop.run_in_executor(
                            None, client.suggest, pinyin, local_cands,
                            ctx_text, obj.get("prefix", ""),
                        )
                        note = f"tokens={usage.get('prompt_tokens')}+{usage.get('completion_tokens')}"
                    except Exception as e:
                        log(f"suggest id={rid} API error: {e!r}")
                        return
                if not texts:
                    log(f"suggest id={rid} empty result, dropped")
                    return
                resp = {"id": rid, "key": key, "cands": texts}
                try:
                    writer.write((json.dumps(resp, ensure_ascii=False) + "\n").encode())
                    await writer.drain()
                except (ConnectionError, RuntimeError):
                    # 客户端已断开（fcitx5 重启等），丢弃结果即可
                    log(f"suggest id={rid} client gone, result dropped")
                    return
                log(
                    f"suggest id={rid} "
                    f"pinyin={pinyin!r} {(time.time() - t0) * 1000:.0f}ms "
                    f"cands={texts!r} {note}"
                )
        finally:
            state["inflight"].discard(key)

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
                state["gen"] += 1
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
