# Changing Hermes Runtime Config (model defaults, display settings)

Runtime config is a git artifact. The pod's copy at `/opt/data/config.yaml` is a cache, re-seeded by
the initContainer on every start — a local edit is drift that the next reload erases. So the change
is the PR; a local set is not a shortcut, it is a lie the next restart exposes.

## Switching the default model

Do NOT touch the pod's config file. Verify first, then PR.

**1. Confirm the ID exists in the provider catalog — never trust a remembered model ID.**
OpenRouter's catalog is public, no key needed:

```bash
curl -s https://openrouter.ai/api/v1/models | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
print([m['id'] for m in d if 'deepseek' in m['id']])"
```

Expect revision siblings (`v4` vs `v4.1`) and `:batch` variants — pick deliberately and say which one
you picked, because the user cares which revision the default pins to.

**2. Prove the network path from inside the pod.** An unauthenticated call should fail with 401 fast:

```bash
curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' -X POST \
  https://openrouter.ai/api/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<id>","messages":[{"role":"user","content":"ping"}]}'
```

`401` in well under a second = DNS and NetworkPolicy egress are fine and only auth is missing. A
hang or timeout is a NetworkPolicy/DNS problem, not a key problem — do not go hunting the key.

**3. Prove the key + model actually work — use the gateway's behaviour as evidence.**
The key is not in your exec shell's env (ESO injects it into the main container only), so the clean
proof is the gateway making real calls with it:

```bash
grep -E 'model=|provider=' /opt/data/logs/agent.log | tail -20
```

A live line showing `model=<id> provider=<provider> ... upstream=<x>` with a latency is one-shot proof
of key + model + egress. `HTTP 429` in that log is provider rate limiting, NOT a bad key.

**4. Edit the ConfigMap, not the pod:**
- `hermes-config-configmap.yaml` → `data.config.yaml` → `model.default: "<id>"`
- also add `<id>` to `providers.<provider>.models` or `/model` cannot select it

**5. Validate and PR:** `kubectl kustomize ai-services/ > /dev/null`, yamllint, PR, merge. The reloader
annotation on the hermes-agent Deployment rolls the pod for you — no second PR, no manual rollout bump.

**6. Verify after the rollout:** `kubectl get pods -n ai-services -l app=hermes-agent` shows a young
pod, and the log shows calls on the new `model=`.

## If you already made a local change

Revert it to git's value immediately (`hermes config get model.default` to see what the pod claims
vs `git show origin/main:./ai-services/hermes-config-configmap.yaml`) and let the merge be the only
actor. Leaving the runtime file ahead of git means a reload silently undoes the switch, and the git
state looks like it never happened.

## Pitfalls

- Pairing the change with a separate rollout PR when the reloader annotation already covers it.
- Setting `model.default` but not adding the ID to `providers.<provider>.models`.
- Treating a 429 as "the key is broken" — it is rate limiting; retry or pick another model.
- Reporting a model switch as done while the runtime copy is ahead of git and no PR exists.
