#!/usr/bin/env python3
"""rime-pause-rank 打分服务（D-30；协议与运维见 ../README.md）。

协议：unix stream socket（$XDG_RUNTIME_DIR/rime-pause-rank/ranker.sock），一请求一连接。
  请求：一行 JSON {"ver": int, "ctx": str, "cands": [str, ...]}，cands 为 Rime 原始顺序的同跨度汉字候选
  响应：一行 "<ver>\t<best>\t<lm_ms>"，best = 融合首选在 cands 中的下标（0 = 维持 Rime 首选）
融合：score_i = log P_LM(cand_i | ctx) − W·ln(1+i)；P0 测评文档集最优 W=1、新闻集 W=2。
打分进程常驻（llm_score，KV 按 head 公共前缀复用），请求串行。
日志：stderr → journal，只记版本、耗时、候选数与改动下标，不记上文与候选原文。
"""
import asyncio
import json
import math
import os
import pathlib
import sys
import time

RUN = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "rime-pause-rank"
SOCK = RUN / "ranker.sock"
BIN = pathlib.Path(__file__).resolve().parent.parent / "build" / "llm_score"
MODEL = os.environ.get("RIME_PAUSE_RANK_MODEL",
                       str(pathlib.Path.home() / "tools/aimodels/Qwen3-0.6B-Base-Q8_0.gguf"))
THREADS = os.environ.get("RIME_PAUSE_RANK_THREADS", "8")
W = float(os.environ.get("RIME_PAUSE_RANK_W", "1"))
MARGIN = float(os.environ.get("RIME_PAUSE_RANK_MARGIN", "0"))   # 融合分须超出 Rime 首选的幅度


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Scorer:
    def __init__(self):
        self.proc = None
        self.lock = asyncio.Lock()
        self.n = 0

    async def ensure(self):
        if self.proc and self.proc.returncode is None:
            return
        self.proc = await asyncio.create_subprocess_exec(
            str(BIN), MODEL, THREADS, "16", "1024",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL)

    async def score(self, ctx, cands):
        async with self.lock:
            await self.ensure()
            self.n += 1
            req = {"id": self.n, "prefix": "", "ctx": ctx, "cands": cands}
            self.proc.stdin.write((json.dumps(req, ensure_ascii=False) + "\n").encode())
            await self.proc.stdin.drain()
            line = await self.proc.stdout.readline()
            if not line:
                self.proc = None
                raise RuntimeError("llm_score exited")
            return json.loads(line)


scorer = Scorer()


async def handle(reader, writer):
    t0 = time.perf_counter()
    try:
        req = json.loads(await asyncio.wait_for(reader.readline(), 2))
        ver, ctx, cands = int(req["ver"]), str(req.get("ctx", "")), [str(c) for c in req["cands"]][:16]
        if len(cands) < 2:
            raise ValueError("cands < 2")
        r = await scorer.score(ctx, cands)
        fused = [s - W * math.log(1 + i) for i, s in enumerate(r["scores"])]
        best = max(range(len(fused)), key=fused.__getitem__)
        if fused[best] - fused[0] <= MARGIN:
            best = 0
        writer.write(f"{ver}\t{best}\t{r['t_ms']:.1f}\n".encode())
        await writer.drain()
        log(f"ver={ver} lm={r['t_ms']:.0f}ms total={(time.perf_counter() - t0) * 1000:.0f}ms "
            f"head_dec={r['n_head_dec']} n={len(cands)} best={best}")
    except (ConnectionResetError, BrokenPipeError):
        log("cancelled: 插件已作废该请求（期间有真实按键）")
    except Exception as e:  # noqa: BLE001 — 任何异常只记类别，不回包（插件超时放弃，输入不受影响）
        log(f"error {type(e).__name__}: {e}")
    finally:
        writer.close()


async def main():
    RUN.mkdir(mode=0o700, exist_ok=True)
    if not BIN.exists():
        sys.exit(f"缺少 {BIN}，先运行 ./run.sh ranker build")
    if SOCK.exists():
        SOCK.unlink()
    await scorer.score("预热", ["预热", "域热"])
    server = await asyncio.start_unix_server(handle, path=str(SOCK))
    os.chmod(SOCK, 0o600)
    log(f"ready model={pathlib.Path(MODEL).name} threads={THREADS} W={W} margin={MARGIN}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
