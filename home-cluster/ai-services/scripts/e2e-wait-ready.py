#!/usr/bin/env python3
"""Wait until the hermes gateway is actually ready to serve.

Stage 1 of the e2e gate. Two steps, both on the agent's own API:

  1. GET /health unauthenticated -- the process is up and the API server is
     listening. This is a shallow answer and comes up early: measured
     2026-09-26, the pod was Ready 22s after container start while the
     gateway's own host claim was not published until ~6 min later. So this
     step alone is not "ready".
  2. GET /health/detailed with Bearer API_SERVER_KEY -- the gateway's own
     bounded readiness report (state.db, session store, config, model, disk,
     gateway platforms). Assert status == ok, checks.gateway.state == running
     and at least one connected platform.

This script asserts nothing about the LLM: it answers "is it up and connected".
The separable question "can it serve a real turn" belongs to e2e-llm-ping.py,
which runs after this one. Keeping them apart is deliberate -- a provider
outage must fail the serve check, never the liveness wait.

Prints no credentials. Exit 0 when ready, 1 when the deadline passes.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request


def resolve_key() -> str:
    """Prefer API_SERVER_KEY; fall back to the first of the OPENAI_API_KEYS list."""
    key = (os.environ.get("API_SERVER_KEY") or "").strip()
    if key:
        return key
    raw = (os.environ.get("OPENAI_API_KEYS") or "").strip()
    if raw:
        return raw.split(";")[0].strip()
    return ""


def get(url: str, key: str, timeout: float):
    req = urllib.request.Request(url)
    if key:
        req.add_header("Authorization", "Bearer " + key)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, json.loads(resp.read().decode("utf-8", "replace"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("E2E_BASE_URL", "http://127.0.0.1:8642"))
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--poll", type=float, default=5.0)
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    key = resolve_key()
    deadline = time.time() + args.timeout
    started = time.time()

    last = None
    while time.time() < deadline:
        try:
            status, _ = get(base + "/health", "", timeout=5)
            if status == 200:
                break
        except Exception as exc:  # noqa: BLE001 - every shape is just "not up yet"
            last = f"{type(exc).__name__}: {exc}"
        time.sleep(min(args.poll, 2.0))
    else:
        print(f"FAIL not_up after {time.time() - started:.1f}s: /health never returned 200 ({last})")
        return 1

    if not key:
        print("FAIL no_api_key: neither API_SERVER_KEY nor OPENAI_API_KEYS is set")
        return 1

    last = None
    while time.time() < deadline:
        try:
            _, body = get(base + "/health/detailed", key, timeout=10)
            gateway = body.get("readiness", {}).get("checks", {}).get("gateway", {})
            if (body.get("status") == "ok"
                    and gateway.get("state") == "running"
                    and gateway.get("connected_platforms", 0) >= 1):
                print(f"READY http=200 after {time.time() - started:.1f}s "
                      f"gateway={gateway.get('state')} "
                      f"connected_platforms={gateway.get('connected_platforms')}")
                return 0
            last = json.dumps({"status": body.get("status"), "gateway": gateway})
        except urllib.error.HTTPError as exc:
            last = f"http_{exc.code}"
        except Exception as exc:  # noqa: BLE001
            last = f"{type(exc).__name__}: {exc}"
        time.sleep(args.poll)

    print(f"FAIL not_ready after {time.time() - started:.1f}s: /health/detailed never reported "
          f"ok/running with a connected platform (last: {last})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
