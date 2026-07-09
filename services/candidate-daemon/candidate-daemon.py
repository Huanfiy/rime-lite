#!/usr/bin/env python3
"""rime-lite AI 候选 daemon（D-17 / D-18）。

职责：unix socket ↔ OpenAI 兼容 API 的桥；工作负载为**生成式智能候补**——
根据会话上下文（近期上屏文本）预测用户想输入的完整内容（拼音整句转换 + 延伸预测，
不受本地词库限制）；请求去抖合并（连打只算稳定态）；API key 托管（配置文件，不入库）。

协议 v1.2（NDJSON over UDS，与 rime/lua/ai/glue.lua 对应）：
  req : {"op":"suggest","id":N,"key":"<缓存键>","pinyin":"<待转换拼音(当前翻译段)>",
         "cands":["本地候选参考",…],"prefix":"<已选定前缀文本,可缺省>","explicit":true|缺省}
        {"op":"commit","text":"<上屏文本>"}
        {"op":"ping"}
  resp: {"id":N,"key":"<原样回显>","cands":["AI 候补文本",…]}   # 最优在前，≤3 条
        {"pong":true,"commits":N}
  v1.1 客户端（无 prefix/explicit 字段）按 auto 请求处理，行为向后兼容。

调度模型（2026-07-09 并发化改造，D-20）：
  auto     请求：音节完整门控 → 去抖（新请求/上屏取代旧任务）→ 并发槽 → API；
  explicit 请求（触发键）：跳过门控与去抖，直接进并发槽，端到端 = API 净耗时；
  上屏（commit）作废所有仍在排队的请求（去抖中 + 等并发槽的，含 explicit）——
  组词态已变、结果注定失配；已在途的 API 调用不中断（token 已花，回包由客户端按 key 失配丢弃）。

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
    "model": "gpt-5.4",
    "reasoning_effort": "low",    # 部分模型不接受该参数（如 spark），置 null 则不发送
    "debounce_ms": 300,           # 去抖：仅输入稳定态触发 API（explicit 请求不受此限）
    "max_concurrency": 3,         # 在途 API 调用上限（并发槽）
    "context_commits": 6,         # 会话上下文保留的上屏条数
    "context_chars": 80,          # 送入 prompt 的上下文尾部长度
    "request_timeout_s": 20,
    "mock_delay_ms": 0,           # mock 模拟 API 延迟（仅 provider=mock，供并发/取消链路验证）
}

# 候补口径单点（ai-daemon.md §8）。2026-07-09 抗锚定修订：真实失败样本显示模型照抄
# 本地整句机械转换（dexingweishi → 照抄「德行为使」而非语境正解「的行为是」），
# 故明确候选定位为「无语境切分参考」、加连读通顺硬约束、附该样本为反例。
SYSTEM_PROMPT = (
    "你是拼音输入法的智能候补引擎。根据上文语境预测用户想输入的完整内容。规则:"
    "输出1到3行,每行一个候补,最优在前;"
    "每个候补必须以给定拼音的中文转换开头,并尽量延伸预测用户接下来要输入的内容(延伸不超过10字);"
    "转换以上文语境为最高依据,候补接在上文之后连读必须通顺;"
    "「本地机械转换」是无语境的词典拼写结果,仅用于理解拼音切分,常与语境不符:"
    "禁止照抄其组词,与上文语义冲突时一律以上文为准;"
    "若给出已选前缀,它是用户本次输入中已确认的开头,与拼音相连成句,"
    "候补只输出拼音对应部分及延伸,禁止重复前缀;"
    "只输出候补文本,不加序号、标点解释。"
    "示例:上文「长按Tab补全」+拼音dexingweishi+本地机械转换「德行为使 德行 的 得」,"
    "正确候补是「的行为是…」(连读「长按Tab补全的行为是」通顺);照抄机械转换输出「德行为使」是典型错误。"
)

_VOWELS = frozenset("aeiouv")


def stable_pinyin(p):
    """音节完整性启发式（auto 请求门控）。

    合法全拼音节只能以元音、n / ng、er 结尾；以悬空辅音结尾的半截输入
    （观测样本：chak / houb / shenm / meiyig）注定在下一键失效，不值得上云。
    宽容误收（如歧义切分）无害——只是多一次调用；严格漏收才有害，故只看尾字符。
    """
    if not p:
        return False
    p = p.rstrip("'")
    if not p or not all("a" <= c <= "z" or c == "'" for c in p):
        return False
    c = p[-1]
    if c in _VOWELS or c == "n":
        return True
    if c == "g" and len(p) >= 2 and p[-2] == "n":
        return True
    if c == "r" and len(p) >= 2 and p[-2] == "e":
        return True
    return False

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
        "latest_auto": None,  # 最新 auto 请求 id：打字推进时取代仍在去抖的旧任务
        "gen": 0,             # 上屏代数：commit 后组词态已变，去抖中的 auto 全部作废
        "inflight": set(),    # 在途 API 的缓存键（同 key 防重）
        "sem": asyncio.Semaphore(max(1, int(cfg["max_concurrency"]))),
    }
    debounce = cfg["debounce_ms"] / 1000.0
    loop = asyncio.get_running_loop()

    async def do_suggest(obj):
        rid, key = obj["id"], obj["key"]
        pinyin = obj.get("pinyin", "")
        explicit = bool(obj.get("explicit"))
        gen0 = state["gen"]
        if not explicit:
            # auto 路径：音节门控 + 去抖；explicit（触发键）跳过两者直达并发槽
            if not stable_pinyin(pinyin):
                return
            state["latest_auto"] = rid
            if debounce > 0:
                await asyncio.sleep(debounce)
            if state["latest_auto"] != rid or state["gen"] != gen0:
                return  # 去抖窗口内被更新输入 / 上屏取代
        if key in state["inflight"]:
            return  # 同 key 已在途（explicit 与 auto 撞车时由在途者供餐）
        state["inflight"].add(key)
        try:
            async with state["sem"]:
                if state["gen"] != gen0:
                    return  # 排队期间已上屏：组词态已变，在队请求（含 explicit）一律作废
                if not explicit and state["latest_auto"] != rid:
                    return  # 排队期间被更新输入取代
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
                    f"suggest id={rid}{' explicit' if explicit else ''} "
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
                state["latest_auto"] = None
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
