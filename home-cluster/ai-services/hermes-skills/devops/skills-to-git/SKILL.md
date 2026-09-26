---
name: skills-to-git
description: "Skills are ephemeral; git is the only durable store. Sync every skill change via PR."
category: devops
version: 1.0.0
author: Hermit
---

# Skills Persistence — Git Is The Only Source of Truth

**Use when:** Creating, editing, or loading ANY skill in this pod, or when wiring skills into the deployment.

## The rule

I am ephemeral. `/opt/data/skills/` is re-materialized from git on every pod start. Any skill created or edited during a session that is NOT in git is lost at the next restart. Therefore: **a skill edit is not done until it is in a merged PR.**

## Where things live

- Git tree: `home-cluster/ai-services/hermes-skills/<category>/<skill-name>/SKILL.md`, plus any
  `references/`, `scripts/`, `templates/` files that skill owns.
- Generator: `configMapGenerator` in `home-cluster/ai-services/kustomization.yaml`, one line per file:
  `- <key>=hermes-skills/<category>/<skill-name>/<path>`. The key is the **relative path with `__`
  substituted for `/`**, because ConfigMap keys cannot contain `/`:

  | Key | Materializes to |
  |---|---|
  | `<cat>__<skill>.md` | `/opt/data/skills/<cat>/<skill>/SKILL.md` |
  | `<skill>.md` (no `__`) | `/opt/data/skills/<skill>/SKILL.md` — categoryless skill |
  | `<cat>__<skill>__<dir>__<file.ext>` | `/opt/data/skills/<cat>/<skill>/<dir>/<file.ext>` |

  The trailing `.md` is **only a marker** meaning "this is the SKILL.md"; on three-or-more-part keys
  the final segment is a real filename and its extension is preserved verbatim.
  The key is the ONLY layout authority — the initContainer parses the key, NOT the frontmatter.

- Pod startup: initContainer in `hermes-agent.yaml` mounts the ConfigMap at `/skills` and walks every
  key to its destination, overriding image-bundled copies. **Keys without `__` used to be skipped
  silently**, which is how two skills stayed git-less for weeks — the parser now handles all three forms.

## What belongs in git (and what does not)

Skills come from two places, and only one of them needs the ConfigMap:

- **Ours** — skills written or edited in this pod. Their `SKILL.md` *and* their supporting files belong
  in git. Check membership with `/opt/data/skills/.bundled_manifest` (`<skill-name>:<hash>` lines):
  a skill *not* listed there is ours.
- **Image-bundled** — pdf, docx, box, xlsx, manim, popular-web-designs and friends, plus their
  references/scripts/templates. They ship in the image; copying them into the ConfigMap would
  duplicate content we do not own and blow the size limit. Leave them alone.

Size budget: measure with
`find home-cluster/ai-services/hermes-skills -type f -printf '%s\n' | awk '{s+=$1} END{print s, s/1048576*100 "%"}'`.
Above ~900 KB, split into a second `configMapGenerator` + volume and extend the initContainer loop.

Verify a key encoding change by running the parser against the real key set **before** committing —
copy the key names into a scratch dir as empty files, run the loop with an output root, and assert every
key lands on its intended path with no extras. The 85-key check takes under a second.

## Procedure after any skill create/edit

1. `git fetch origin && git checkout -b <name> origin/main` (never work on stale main)
2. Copy the updated `SKILL.md` into `ai-services/hermes-skills/<category>/<name>/SKILL.md`
3. Add/update its key line in the `kustomization.yaml` configMapGenerator
4. `kubectl kustomize ai-services/ > /dev/null` — build must pass (catches missing files, duplicate keys)
5. Size check: ConfigMap hard limit is 1 MiB. `find ai-services/hermes-skills -name SKILL.md -printf '%s\n' | awk '{s+=$1} END{print s}'` must stay under ~900k. If approaching, split into a second generator + volume and extend the initContainer loop.
6. PR → CI green → user merges → Flux reconciles → next pod restart materializes skills.

## Verify after merge (read-only kubectl)

```bash
kubectl get configmap -n ai-services | grep hermes-skills
kubectl get pods -n ai-services -l app=hermes-agent
```

## Pitfalls

- Editing a skill and calling it "saved" without a PR — it dies on restart.
- Relying on frontmatter `category:` for the mount path — the key name wins.
- Two skills mapping to the same `<cat>__<name>` key — kustomize build fails.
- Skill content that embeds secret values — paths to ESO-managed files are fine, values never.
- Adding a skill file without its `configMapGenerator` line — it sits in git and never mounts.

## Runtime state is not ownership

`/opt/data` (config.yaml, skills/, memory) is a **cache**, not the source of truth. It is
re-seeded from git on every reload, so an edit made directly at runtime is not a change —
it is temporary drift that gets silently reverted.

- **Never** use `hermes config set` / direct file writes to make a durable change to config,
  model defaults, or skills. Open the PR. Merging it rolls the pod via the reloader
  annotation on the hermes-agent Deployment
  (`configmap.reloader.stakater.com/reload: "hermes-config,hermes-skills,hermes-soul"`)
  and the initContainer re-seeds from the ConfigMaps.
- When asked to "switch yourself to X", the deliverable is a **PR**, not a local set.
  Say that, don't take the shortcut — a local set is drift that a reload erases, and it
  makes the git state look like it never happened.
- Same rule as skills: nothing is done until it is merged.
