#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["aiohttp"]
# ///
"""
Stress test for MCP Streamable HTTP server.
Runs multiple scenario types concurrently, reporting per-scenario stats.

Usage:
    # Start conformance server first:
    #   sbcl --load conformance-server.lisp
    uv run stress-test.py [--url URL] [--concurrency N] [--interval SECS]
"""

import argparse
import asyncio
import json
import random
import signal
import time
import sys
from dataclasses import dataclass, field

try:
    import aiohttp
except ImportError:
    print("pip install aiohttp", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

def percentile(data, p):
    if not data:
        return 0
    s = sorted(data)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = f + 1 if f + 1 < len(s) else f
    return s[f] + (k - f) * (s[c] - s[f])


@dataclass
class ScenarioStats:
    sessions: int = 0
    requests: int = 0
    errors: int = 0
    assertions_failed: int = 0
    latencies: list = field(default_factory=list)

    def record(self, dt_ms):
        self.requests += 1
        self.latencies.append(dt_ms)

    def record_error(self, dt_ms):
        self.errors += 1
        self.requests += 1
        self.latencies.append(dt_ms)

    def snapshot_and_reset_latencies(self):
        snap = {
            "sessions": self.sessions,
            "requests": self.requests,
            "errors": self.errors,
            "assertions_failed": self.assertions_failed,
            "p50": percentile(self.latencies, 50),
            "p95": percentile(self.latencies, 95),
        }
        self.latencies.clear()
        return snap


class Stats:
    def __init__(self):
        self.by_scenario: dict[str, ScenarioStats] = {}

    def get(self, name: str) -> ScenarioStats:
        if name not in self.by_scenario:
            self.by_scenario[name] = ScenarioStats()
        return self.by_scenario[name]

    @property
    def total_requests(self):
        return sum(s.requests for s in self.by_scenario.values())

    @property
    def total_errors(self):
        return sum(s.errors for s in self.by_scenario.values())

    @property
    def total_assertions_failed(self):
        return sum(s.assertions_failed for s in self.by_scenario.values())

    @property
    def total_sessions(self):
        return sum(s.sessions for s in self.by_scenario.values())


# ---------------------------------------------------------------------------
# MCP client session
# ---------------------------------------------------------------------------

class MCPSession:
    def __init__(self, url: str, http: aiohttp.ClientSession, scenario_stats: ScenarioStats):
        self.url = url
        self.http = http
        self.stats = scenario_stats
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
                self.stats.record(dt)

                if method == "initialize" and "MCP-Session-Id" in resp.headers:
                    self.session_id = resp.headers["MCP-Session-Id"]

                ct = resp.headers.get("Content-Type", "")
                if "text/event-stream" in ct:
                    return self._parse_sse(body)
                else:
                    return json.loads(body)
        except Exception:
            dt = (time.monotonic() - t0) * 1000
            self.stats.record_error(dt)
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
                self.stats.record(0)
        except Exception:
            self.stats.record_error(0)

    async def delete(self):
        if not self.session_id:
            return
        headers = {"MCP-Session-Id": self.session_id}
        try:
            async with self.http.delete(self.url, headers=headers) as resp:
                await resp.read()
        except Exception:
            pass

    async def initialize(self):
        await self.call("initialize", {
            "protocolVersion": "2025-11-25",
            "capabilities": {"sampling": {}},
            "clientInfo": {"name": "stress-test", "version": "1.0"},
        })
        await self.notify("notifications/initialized")

    def _parse_sse(self, body: str) -> dict:
        last = {}
        for line in body.split("\n"):
            if line.startswith("data: "):
                try:
                    last = json.loads(line[6:])
                except json.JSONDecodeError:
                    pass
        return last

    def assert_result_contains(self, response: dict, needle: str, context: str = ""):
        result = response.get("result", {})
        content = result.get("content", [])
        text = ""
        if content:
            text = content[0].get("text", "") if isinstance(content[0], dict) else ""
        if needle not in text:
            self.stats.assertions_failed += 1

    def assert_resource_text_contains(self, response: dict, needle: str):
        """Assert the first resource content entry's text contains needle."""
        contents = response.get("result", {}).get("contents", [])
        text = contents[0].get("text", "") if contents else ""
        if needle not in text:
            self.stats.assertions_failed += 1

    def assert_resource_has_blob(self, response: dict):
        """Assert the first resource content entry has a non-empty blob."""
        contents = response.get("result", {}).get("contents", [])
        blob = contents[0].get("blob", "") if contents else ""
        if not blob:
            self.stats.assertions_failed += 1

    def assert_is_error(self, response: dict, context: str = ""):
        result = response.get("result", {})
        if not result.get("isError"):
            err = response.get("error")
            if not err:
                self.stats.assertions_failed += 1


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

async def scenario_simple_tools(url: str, http: aiohttp.ClientSession, stats: Stats, stop: asyncio.Event):
    """Calls conformance fixture tools — no state, no streaming."""
    ss = stats.get("simple")
    while not stop.is_set():
        s = MCPSession(url, http, ss)
        try:
            await s.initialize()
            await s.call("ping")
            await s.call("tools/list")

            for name in ["test_simple_text", "test_image_content", "test_audio_content",
                         "test_embedded_resource", "test_multiple_content_types"]:
                resp = await s.call("tools/call", {"name": name, "arguments": {}})
                s.assert_result_contains(resp, "", name)

            resp = await s.call("tools/call", {"name": "test_error_handling", "arguments": {}})
            s.assert_is_error(resp, "test_error_handling")

            await s.call("resources/list")

            resp = await s.call("resources/read", {"uri": "test://static-text"})
            s.assert_resource_text_contains(resp, "static text resource")

            resp = await s.call("resources/read", {"uri": "test://static-binary"})
            s.assert_resource_has_blob(resp)

            rid = random.randint(1, 9999)
            resp = await s.call("resources/read", {"uri": f"test://template/{rid}/data"})
            s.assert_resource_text_contains(resp, str(rid))

            await s.call("resources/subscribe", {"uri": "test://static-text"})
            await s.call("resources/unsubscribe", {"uri": "test://static-text"})

            await s.call("prompts/list")
            await s.call("prompts/get", {"name": "test_simple_prompt"})
            await s.call("prompts/get", {
                "name": "test_prompt_with_arguments",
                "arguments": {"arg1": "hello", "arg2": "world"},
            })

            await s.call("completion/complete", {
                "ref": {"type": "ref/prompt", "name": "test_simple_prompt"},
                "argument": {"name": "text", "value": "hel"},
            })
            await s.call("logging/setLevel", {"level": "info"})
            await s.delete()
            ss.sessions += 1
        except Exception:
            await asyncio.sleep(0.1)


async def scenario_eval_lisp(url: str, http: aiohttp.ClientSession, stats: Stats, stop: asyncio.Event):
    """Multi-step eval_lisp: define, call with random inputs, verify computed results, clear, verify gone."""
    ss = stats.get("eval")
    while not stop.is_set():
        s = MCPSession(url, http, ss)
        try:
            await s.initialize()

            # Define square
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": "(defun square (x) (* x x))"
            }})
            s.assert_result_contains(resp, "SQUARE")

            # Call with random input, verify result
            a = random.randint(1, 100)
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": f"(square {a})"
            }})
            s.assert_result_contains(resp, str(a * a))

            # Build sum-of-squares on top
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": "(defun sum-of-squares (a b) (+ (square a) (square b)))"
            }})
            s.assert_result_contains(resp, "SUM-OF-SQUARES")

            b, c = random.randint(1, 50), random.randint(1, 50)
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": f"(sum-of-squares {b} {c})"
            }})
            s.assert_result_contains(resp, str(b * b + c * c))

            # Accumulator with random count
            n = random.randint(3, 20)
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": f"(let ((acc 0)) (dotimes (i {n}) (incf acc (1+ i))) acc)"
            }})
            expected = sum(range(1, n + 1))
            s.assert_result_contains(resp, str(expected))

            # Fibonacci — heavier computation
            fib_n = random.randint(5, 15)
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": f"(labels ((fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib {fib_n}))"
            }})
            def pyfib(n):
                a, b = 0, 1
                for _ in range(n):
                    a, b = b, a + b
                return a
            s.assert_result_contains(resp, str(pyfib(fib_n)))

            # Printed output with random token
            token = random.randint(10000, 99999)
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": f'(format t "token-{token}")'
            }})
            s.assert_result_contains(resp, f"token-{token}")

            # Clear and verify isolation
            await s.call("tools/call", {"name": "clear_repl", "arguments": {}})

            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": "(square 5)"
            }})
            s.assert_result_contains(resp, "Error")

            await s.delete()
            ss.sessions += 1
        except Exception:
            await asyncio.sleep(0.1)


async def scenario_errors(url: str, http: aiohttp.ClientSession, stats: Stats, stop: asyncio.Event):
    """Edge cases: bad tool names, malformed requests, missing sessions."""
    ss = stats.get("errors")
    while not stop.is_set():
        s = MCPSession(url, http, ss)
        try:
            await s.initialize()

            # Nonexistent tool
            resp = await s.call("tools/call", {"name": "nonexistent_tool_xyz", "arguments": {}})
            err = resp.get("error")
            if not err and not resp.get("result", {}).get("isError"):
                ss.assertions_failed += 1

            # Missing tool name
            resp = await s.call("tools/call", {"arguments": {}})
            if "error" not in resp:
                ss.assertions_failed += 1

            # Eval with syntax error
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": "(defun incomplete"
            }})
            s.assert_result_contains(resp, "Error")

            # Eval with runtime error
            resp = await s.call("tools/call", {"name": "eval_lisp", "arguments": {
                "code": "(/ 1 0)"
            }})
            s.assert_result_contains(resp, "Error")

            # Nonexistent resource
            resp = await s.call("resources/read", {"uri": "test://does-not-exist"})
            if "error" not in resp:
                ss.assertions_failed += 1

            # Nonexistent prompt
            resp = await s.call("prompts/get", {"name": "no_such_prompt"})
            if "error" not in resp:
                ss.assertions_failed += 1

            await s.delete()
            ss.sessions += 1
        except Exception:
            await asyncio.sleep(0.1)


SCENARIOS = {
    "simple": scenario_simple_tools,
    "eval":   scenario_eval_lisp,
    "errors": scenario_errors,
}


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

async def get_health(url: str) -> dict | None:
    health_url = url.rsplit("/", 1)[0] + "/health"
    try:
        timeout = aiohttp.ClientTimeout(total=2)
        async with aiohttp.ClientSession(timeout=timeout) as http:
            async with http.get(health_url) as resp:
                return await resp.json()
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

COL = {
    "scenario": 10, "sessions": 8, "reqs": 8, "errs": 5,
    "assert": 6, "rps": 7, "p50": 8, "p95": 8,
}

def print_header():
    print(f"{'scenario':>{COL['scenario']}}  {'sessions':>{COL['sessions']}}  "
          f"{'reqs':>{COL['reqs']}}  {'errs':>{COL['errs']}}  "
          f"{'assert':>{COL['assert']}}  {'req/s':>{COL['rps']}}  "
          f"{'p50':>{COL['p50']}}  {'p95':>{COL['p95']}}")
    print("-" * 72)


def print_scenario_line(name: str, snap: dict, rps: float):
    print(f"{name:>{COL['scenario']}}  {snap['sessions']:>{COL['sessions']}d}  "
          f"{snap['requests']:>{COL['reqs']}d}  {snap['errors']:>{COL['errs']}d}  "
          f"{snap['assertions_failed']:>{COL['assert']}d}  {rps:>{COL['rps']}.0f}  "
          f"{snap['p50']:>{COL['p50']}.1f}ms  {snap['p95']:>{COL['p95']}.1f}ms")


async def main():
    parser = argparse.ArgumentParser(description="MCP server stress test")
    parser.add_argument("--url", default="http://localhost:8080/mcp")
    parser.add_argument("--concurrency", type=int, default=10,
                        help="Total concurrent workers (distributed across scenarios)")
    parser.add_argument("--interval", type=int, default=5, help="Seconds between reports")
    args = parser.parse_args()

    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    loop.add_signal_handler(signal.SIGINT, stop.set)

    stats = Stats()
    health_before = await get_health(args.url)

    print(f"Stress test: {args.url}  ({args.concurrency} workers, reporting every {args.interval}s)")
    print(f"Scenarios: {', '.join(SCENARIOS.keys())}")
    print(f"Press Ctrl-C to stop.")
    if health_before:
        print(f"  start: heap={health_before['heap_mb']}MB threads={health_before['threads']}")
    print()

    # Distribute workers across scenarios: weighted by complexity
    weights = {"simple": 4, "eval": 4, "errors": 2}
    total_weight = sum(weights.values())
    allocations = {}
    remaining = args.concurrency
    for i, (name, w) in enumerate(weights.items()):
        if i == len(weights) - 1:
            allocations[name] = remaining
        else:
            n = max(1, round(args.concurrency * w / total_weight))
            allocations[name] = n
            remaining -= n

    for name, n in allocations.items():
        print(f"  {name}: {n} workers")
    print()

    workers = []
    for scenario_name, scenario_fn in SCENARIOS.items():
        n = allocations.get(scenario_name, 1)
        for _ in range(n):
            async def run(fn=scenario_fn):
                async with aiohttp.ClientSession() as http:
                    await fn(args.url, http, stats, stop)
            workers.append(asyncio.create_task(run()))

    prev_reqs = {}
    t0 = time.monotonic()

    try:
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=args.interval)
            except asyncio.TimeoutError:
                pass

            elapsed = time.monotonic() - t0
            print(f"\n--- {elapsed:.0f}s ---")
            print_header()

            total_rps = 0
            for name in SCENARIOS:
                ss = stats.get(name)
                snap = ss.snapshot_and_reset_latencies()
                prev = prev_reqs.get(name, 0)
                interval_reqs = snap["requests"] - prev
                rps = interval_reqs / args.interval if args.interval else 0
                prev_reqs[name] = snap["requests"]
                total_rps += rps
                print_scenario_line(name, snap, rps)

            print(f"{'TOTAL':>{COL['scenario']}}  {stats.total_sessions:>{COL['sessions']}d}  "
                  f"{stats.total_requests:>{COL['reqs']}d}  {stats.total_errors:>{COL['errs']}d}  "
                  f"{stats.total_assertions_failed:>{COL['assert']}d}  {total_rps:>{COL['rps']}.0f}")
    finally:
        stop.set()
        await asyncio.gather(*workers, return_exceptions=True)

    elapsed = time.monotonic() - t0
    health_after = await get_health(args.url)

    print(f"\n{'='*72}")
    print(f"Total: {elapsed:.0f}s  {stats.total_sessions} sessions  "
          f"{stats.total_requests} requests  {stats.total_errors} errors  "
          f"{stats.total_assertions_failed} assertion failures  "
          f"{stats.total_requests/elapsed:.0f} req/s")
    if health_before and health_after:
        delta = health_after["heap_mb"] - health_before["heap_mb"]
        print(f"Memory: {health_before['heap_mb']}MB -> {health_after['heap_mb']}MB "
              f"({'+' if delta >= 0 else ''}{delta}MB)")
        if health_after["pending_responses"] > 0:
            print(f"  *** {health_after['pending_responses']} leaked pending responses ***")
        if health_after["sse_clients"] > 0:
            print(f"  *** {health_after['sse_clients']} leaked SSE clients ***")

    return 1 if (stats.total_errors or stats.total_assertions_failed) else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
