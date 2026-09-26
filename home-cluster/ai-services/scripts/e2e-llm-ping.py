#!/usr/bin/env python3
"""End-to-end LLM liveness probe: send "ping", require a real completion back.

Answers the question a Kubernetes probe must NOT answer: not "is the process up"
(that is /health, dependency-free, 2ms) but "can this deployment serve a real
turn" -- auth wired, provider reachable, model routable, gateway not wedged.

Design constraints baked in on purpose:
  * Never kills the pod. Exit code is consumed by a gate/alert, not by the kubelet.
  * The HARD assertion is HTTP 200 + non-empty choices[0].message.content. That is
    what catches credential/provider/model misconfiguration -- today's actual
    incident class.
  * The "pong" match is a SOFT signal, logged as evidence, not asserted. Pinning a
    test to exact LLM output makes it fail on every model swap, and this
    deployment's model routing changed three times in one day.
  * Prints no credentials and no full response body.

Usage:
  e2e-llm-ping.py [--base-url URL] [--model NAME] [--timeout SECS]
Exit: 0 pass, 1 fail (machine-readable reason on stdout).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_MODEL = "cohere/north-mini-code:free"


def resolve_key() -> str:
    """Prefer API_SERVER_KEY; fall back to the first of the OPENAI_API_KEYS list."""
    key = (os.environ.get("API_SERVER_KEY") or "").strip()
    if key:
        return key
    raw = (os.environ.get("OPENAI_API_KEYS") or "").strip()
    if raw:
        return raw.split(";")[0].strip()
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("E2E_BASE_URL", "http://127.0.0.1:8642"))
    ap.add_argument("--model", default=os.environ.get("E2E_MODEL", DEFAULT_MODEL))
    ap.add_argument("--timeout", type=float, default=45.0)
    ap.add_argument("--prompt", default="Reply with exactly one word: pong")
    ap.add_argument("--expect-regex-soft", default="pong")
    args = ap.parse_args()

    key = resolve_key()
    if not key:
        print("FAIL no_api_key: neither API_SERVER_KEY nor OPENAI_API_KEYS is set")
        return 1

    payload = json.dumps(
        {
            "model": args.model,
            "messages": [{"role": "user", "content": args.prompt}],
            "max_tokens": 8,
            "temperature": 0,
        }
    ).encode()

    req = urllib.request.Request(
        args.base_url.rstrip("/") + "/v1/chat/completions",
        data=payload,
        method="POST",
    )
    req.add_header("Authorization", "Bearer " + key)
    req.add_header("Content-Type", "application/json")

    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            status = resp.status
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        print(f"FAIL http_{exc.code} after {time.time() - started:.1f}s: {detail}")
        return 1
    except Exception as exc:  # noqa: BLE001 - probe must classify every failure
        print(f"FAIL transport after {time.time() - started:.1f}s: {type(exc).__name__}: {exc}")
        return 1

    elapsed = time.time() - started
    if status != 200:
        print(f"FAIL status_{status} after {elapsed:.1f}s")
        return 1

    try:
        data = json.loads(body)
        content = (data["choices"][0]["message"]["content"] or "").strip()
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL unparseable_response after {elapsed:.1f}s: {type(exc).__name__} "
              f"body_starts={body[:80]!r}")
        return 1

    if not content:
        print(f"FAIL empty_completion after {elapsed:.1f}s model={args.model}")
        return 1

    soft = args.expect_regex_soft.lower() in content.lower()
    print(f"PASS http=200 latency={elapsed:.1f}s model={args.model} "
          f"completion_len={len(content)} soft_pong_match={soft}")
    if not soft:
        print(f"NOTE completion did not contain {args.expect_regex_soft!r} "
              f"(not asserted -- exact LLM output is not a stable contract); "
              f"model={args.model}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
