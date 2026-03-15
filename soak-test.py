#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["aiohttp"]
# ///
"""
Soak/stress test for MCP Streamable HTTP server.
Runs continuously until Ctrl-C, printing periodic health/stats summaries.

Usage:
    # Start conformance server first:
    #   sbcl --load conformance-server.lisp
    uv run soak-test.py [--url URL] [--concurrency N] [--interval SECS]
"""

import argparse
import asyncio
import json
import signal
import time
import sys
from dataclasses import dataclass, field
from collections import defaultdict

try:
    import aiohttp
except ImportError:
    print("pip install aiohttp", file=sys.stderr)
    sys.exit(1)


@dataclass
class Stats:
    requests: int = 0
    sessions: int = 0
    errors: int = 0
    latencies: list = field(default_factory=list)
    by_method: dict = field(default_factory=lambda: defaultdict(lambda: {"count": 0, "errors": 0, "latencies": []}))

    def snapshot(self):
        """Return current counters and reset latencies for the next interval."""
        snap = {
            "requests": self.requests,
            "sessions": self.sessions,
            "errors": self.errors,
            "p50": percentile(self.latencies, 50),
            "p95": percentile(self.latencies, 95),
            "p99": percentile(self.latencies, 99),
        }
        self.latencies.clear()
        for m in self.by_method.values():
            m["latencies"].clear()
        return snap


def percentile(data, p):
    if not data:
        return 0
    s = sorted(data)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = f + 1 if f + 1 < len(s) else f
    return s[f] + (k - f) * (s[c] - s[f])


class MCPSession:
    """A single MCP client session."""

    def __init__(self, url: str, session: aiohttp.ClientSession, stats: Stats):
        self.url = url
        self.http = session
        self.stats = stats
        self.next_id = 0
        self.session_id = None

    async def call(self, method: str, params: dict = None) -> dict:
        self.next_id += 1
        req = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params:
            req["params"] = params

        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id

        t0 = time.monotonic()
        try:
            async with self.http.post(self.url, json=req, headers=headers) as resp:
                body = await resp.text()
                dt = (time.monotonic() - t0) * 1000

                self.stats.requests += 1
                self.stats.latencies.append(dt)
                m = self.stats.by_method[method]
                m["count"] += 1
                m["latencies"].append(dt)

                if method == "initialize" and "MCP-Session-Id" in resp.headers:
                    self.session_id = resp.headers["MCP-Session-Id"]

                ct = resp.headers.get("Content-Type", "")
                if "text/event-stream" in ct:
                    return self._parse_sse(body)
                else:
                    return json.loads(body)
        except Exception:
            dt = (time.monotonic() - t0) * 1000
            self.stats.errors += 1
            self.stats.latencies.append(dt)
            m = self.stats.by_method[method]
            m["errors"] += 1
            m["latencies"].append(dt)
            raise

    async def notify(self, method: str, params: dict = None):
        req = {"jsonrpc": "2.0", "method": method}
        if params:
            req["params"] = params

        headers = {"Content-Type": "application/json"}
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id

        try:
            async with self.http.post(self.url, json=req, headers=headers) as resp:
                await resp.read()
                self.stats.requests += 1
                self.stats.by_method[method]["count"] += 1
        except Exception:
            self.stats.errors += 1
            self.stats.by_method[method]["errors"] += 1

    def _parse_sse(self, body: str) -> dict:
        for line in body.split("\n"):
            if line.startswith("data: "):
                return json.loads(line[6:])
        return {}

    async def run_session(self):
        """Run a full MCP session lifecycle."""
        result = await self.call("initialize", {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "soak-test", "version": "1.0"},
        })
        await self.notify("notifications/initialized")
        await self.call("ping")

        await self.call("tools/list")
        for tool_name in ["test_simple_text", "test_image_content", "test_audio_content",
                          "test_embedded_resource", "test_multiple_content_types",
                          "test_error_handling"]:
            await self.call("tools/call", {"name": tool_name, "arguments": {}})

        await self.call("resources/list")
        await self.call("resources/read", {"uri": "test://static-text"})
        await self.call("resources/read", {"uri": "test://static-binary"})
        await self.call("resources/read", {"uri": "test://template/42/data"})
        await self.call("resources/subscribe", {"uri": "test://static-text"})
        await self.call("resources/unsubscribe", {"uri": "test://static-text"})

        await self.call("prompts/list")
        await self.call("prompts/get", {"name": "test_simple_prompt"})
        await self.call("prompts/get", {
            "name": "test_prompt_with_arguments",
            "arguments": {"arg1": "hello", "arg2": "world"},
        })
        await self.call("completion/complete", {
            "ref": {"type": "ref/prompt", "name": "test_simple_prompt"},
            "argument": {"name": "text", "value": "hel"},
        })
        await self.call("logging/setLevel", {"level": "info"})
        self.stats.sessions += 1


async def run_worker(url: str, stats: Stats, stop: asyncio.Event):
    """Run sessions in a loop until stopped."""
    async with aiohttp.ClientSession() as http:
        while not stop.is_set():
            session = MCPSession(url, http, stats)
            try:
                await session.run_session()
            except Exception:
                await asyncio.sleep(0.1)


async def get_health(url: str) -> dict | None:
    health_url = url.rsplit("/", 1)[0] + "/health"
    try:
        async with aiohttp.ClientSession() as http:
            async with http.get(health_url) as resp:
                return await resp.json()
    except Exception:
        return None


async def main():
    parser = argparse.ArgumentParser(description="MCP server soak test")
    parser.add_argument("--url", default="http://localhost:8080/mcp")
    parser.add_argument("--concurrency", type=int, default=10, help="Concurrent workers")
    parser.add_argument("--interval", type=int, default=5, help="Seconds between status reports")
    args = parser.parse_args()

    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    loop.add_signal_handler(signal.SIGINT, stop.set)

    stats = Stats()
    health_before = await get_health(args.url)

    print(f"Soak test: {args.url}  ({args.concurrency} workers, reporting every {args.interval}s)")
    print(f"Press Ctrl-C to stop.")
    if health_before:
        print(f"  start: heap={health_before['heap_mb']}MB threads={health_before['threads']}")
    print()
    print(f"{'elapsed':>8s}  {'sessions':>8s}  {'requests':>9s}  {'errors':>6s}  {'req/s':>7s}  {'p50':>6s}  {'p95':>6s}  {'p99':>6s}  {'heap':>5s}")
    print("-" * 82)

    t0 = time.monotonic()
    prev_reqs = 0

    workers = [
        asyncio.create_task(run_worker(args.url, stats, stop))
        for _ in range(args.concurrency)
    ]

    try:
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=args.interval)
            except asyncio.TimeoutError:
                pass

            elapsed = time.monotonic() - t0
            snap = stats.snapshot()
            interval_reqs = snap["requests"] - prev_reqs
            rps = interval_reqs / args.interval if args.interval else 0
            prev_reqs = snap["requests"]

            health = await get_health(args.url)
            heap = f"{health['heap_mb']}MB" if health else "?"

            print(f"{elapsed:>7.0f}s  {snap['sessions']:>8d}  {snap['requests']:>9d}  {snap['errors']:>6d}  {rps:>7.0f}  {snap['p50']:>5.1f}ms {snap['p95']:>5.1f}ms {snap['p99']:>5.1f}ms  {heap:>5s}")
    finally:
        stop.set()
        await asyncio.gather(*workers, return_exceptions=True)

    elapsed = time.monotonic() - t0
    health_after = await get_health(args.url)

    print("-" * 82)
    print(f"Total: {elapsed:.0f}s  {stats.sessions} sessions  {stats.requests} requests  {stats.errors} errors  {stats.requests/elapsed:.0f} req/s")
    if health_before and health_after:
        delta = health_after["heap_mb"] - health_before["heap_mb"]
        print(f"Memory: {health_before['heap_mb']}MB -> {health_after['heap_mb']}MB ({'+' if delta >= 0 else ''}{delta}MB)")
        if health_after["pending_responses"] > 0:
            print(f"  *** {health_after['pending_responses']} leaked pending responses ***")
        if health_after["sse_clients"] > 0:
            print(f"  *** {health_after['sse_clients']} leaked SSE clients ***")

    return 1 if stats.errors else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
