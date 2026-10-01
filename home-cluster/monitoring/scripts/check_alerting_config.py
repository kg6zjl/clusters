#!/usr/bin/env python3
"""Validate the two generated alerting artifacts before they reach the cluster.

Both are strings that only the consumer can parse:

  * every PrometheusRule manifest's spec.groups -> `promtool check rules`
  * the ExternalSecret's rendered `alertmanager.yaml` -> `amtool check-config`

Neither is checked by `kustomize build` (a broken rule expression is still valid YAML) and
Prometheus refuses the WHOLE rule set on one bad rule, restoring the previous set - a silent
no-op rather than an outage, which is exactly why this runs in CI.

The Alertmanager config is not valid on its own: it is a Go template rendered by External
Secrets, so the ESO escapes are undone and the ESO-only placeholders are replaced with dummies
before amtool sees it. Only placeholder NAMES are printed - never a value - and after the
2026-09-30 change the only placeholder left is the ntfy URL; the Discord webhook and the
message templates are files now.

Usage: check_alerting_config.py [--promtool PATH] [--amtool PATH] [--repo-root DIR]
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ESO_ESCAPES = [('{{ "{{" }}', "{{"), ('{{ "}}" }}', "}}")]
PLACEHOLDER = re.compile(r"\{\{\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
CONFIGMAP_DIR = "/etc/alertmanager/configmaps/"
SECRET_DIR = "/etc/alertmanager/secrets/"


def load_docs(path):
    try:
        return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        raise SystemExit(f"{path}: not parseable as YAML: {exc}")


def check_rules(hc_root, promtool, tmp):
    files, checked, rules = [], 0, 0
    for path in sorted(list(hc_root.rglob("*.yaml")) + list(hc_root.rglob("*.yml"))):
        for doc in load_docs(path):
            if doc.get("kind") != "PrometheusRule":
                continue
            groups = (doc.get("spec") or {}).get("groups") or []
            if not groups:
                print(f"  FAIL {path.relative_to(hc_root)}: PrometheusRule with no groups")
                return 1
            out = tmp / (path.stem + ".rules.yaml")
            out.write_text(yaml.safe_dump({"groups": groups}, sort_keys=False, width=10 ** 6))
            res = subprocess.run([promtool, "check", "rules", str(out)],
                                 capture_output=True, text=True)
            files.append(str(path.relative_to(hc_root)))
            checked += len(groups)
            rules += sum(len(g.get("rules") or []) for g in groups)
            if res.returncode != 0:
                print(f"  FAIL {path.relative_to(hc_root)}: {res.stdout.strip()} {res.stderr.strip()}")
                return 1
    if not files:
        # A glob that matches nothing passes silently, which is the failure this gate exists to
        # prevent: no rule file checked at all must not read as "rules are fine".
        print("  FAIL: no PrometheusRule manifest found under", hc_root)
        return 1
    print(f"  promtool check rules: {len(files)} PrometheusRule manifests, {checked} groups, "
          f"{rules} rules - all parse")
    return 0


def build_alertmanager_config(mon_dir, hc_root, tmp):
    """Return (path to a renderable alertmanager.yaml, list of substituted placeholder names)."""
    source, eso = None, None
    for path in sorted(mon_dir.glob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") == "ExternalSecret" and "alertmanager.yaml" in (
                    ((doc.get("spec") or {}).get("target") or {}).get("template") or {}).get("data", {}):
                source, eso = path, doc
    if eso is None:
        raise SystemExit("no ExternalSecret renders an alertmanager.yaml")

    text = eso["spec"]["target"]["template"]["data"]["alertmanager.yaml"]
    for escaped, real in ESO_ESCAPES:
        text = text.replace(escaped, real)
    assert '{{ "' not in text or '{{ "{{" }}' not in text, "unhandled ESO escaping left in the config"

    names = set(PLACEHOLDER.findall(text))
    secret_keys = [d["secretKey"] for d in eso["spec"].get("data") or []]
    # A name that is not a key of this Secret is either an Alertmanager field (exported struct
    # field, so always CamelCase: .Status, .CommonLabels, .GeneratorURL) or an ESO placeholder
    # this file forgot to declare - and that one is lower-case. Only the latter is a failure:
    # left alone, ESO emits it literally and Alertmanager treats the secret name as a field.
    unknown = {n for n in names if n not in secret_keys and not n[0].isupper()}
    if unknown:
        print(f"  FAIL {source.name}: ESO placeholder(s) with no matching spec.data key: "
              f"{sorted(unknown)}")
        return None, None, 1
    eso_names = sorted(set(names) & set(secret_keys))
    for k in eso_names:
        text = text.replace("{{ .%s }}" % k, "DUMMY-%s" % k)
    print(f"  ESO placeholders substituted (names only): {eso_names or 'none'}")
    print(f"  Alertmanager templates left intact: {sorted(names - set(eso_names))}")

    # Point `templates:` at the .tmpl files this repo carries, so amtool parses them too.
    configmaps = {}
    for path in sorted(hc_root.rglob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") == "ConfigMap" and doc.get("metadata", {}).get("name"):
                configmaps[doc["metadata"]["name"]] = doc
    secrets = set()
    for path in sorted(hc_root.rglob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") in ("Secret", "ExternalSecret"):
                name = (doc.get("metadata") or {}).get("name")
                target = ((doc.get("spec") or {}).get("target") or {})
                secrets |= {n for n in (name, target.get("name")) if n}

    tmpl_dir = tmp / "templates"
    tmpl_dir.mkdir()
    for entry in re.findall(r"^\s+- (\S+)$", text, re.M):
        if entry.startswith(CONFIGMAP_DIR):
            cm_name = entry[len(CONFIGMAP_DIR):].split("/")[0]
            cm = configmaps.get(cm_name)
            if cm is None:
                print(f"  FAIL {source.name}: templates: names ConfigMap {cm_name!r}, "
                      "which no manifest in this repo defines")
                return None, None, 1
            (tmpl_dir / os.path.basename(entry)).write_text(cm.get("data", {}).get("discord.tmpl", ""))
            text = text.replace(entry, str(tmpl_dir / os.path.basename(entry)))
        elif entry.startswith(SECRET_DIR):
            secret = entry[len(SECRET_DIR):].split("/")[0]
            if secret not in secrets:
                print(f"  FAIL {source.name}: {entry} names Secret {secret!r}, which no manifest "
                      "in this repo defines")
                return None, None, 1
    if not list(tmpl_dir.iterdir()):
        print("  FAIL: the config references no template file")
        return None, None, 1

    out = tmp / "alertmanager.yaml"
    out.write_text(text)
    return out, names, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--promtool", default=os.environ.get("PROMTOOL", "promtool"))
    ap.add_argument("--amtool", default=os.environ.get("AMTOOL", "amtool"))
    ap.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[3]))
    args = ap.parse_args()

    hc_root = Path(args.repo_root) / "home-cluster"
    mon_dir = hc_root / "monitoring"
    print("Alerting config checks")

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        rc = check_rules(hc_root, args.promtool, tmp)
        if rc:
            return rc
        config, names, rc = build_alertmanager_config(mon_dir, hc_root, tmp)
        if rc:
            return rc
        res = subprocess.run([args.amtool, "check-config", str(config)],
                             capture_output=True, text=True)
        print("  amtool check-config:\n" + "\n".join(
            "    " + l for l in (res.stdout + res.stderr).strip().split("\n")))
        if res.returncode != 0:
            return 1
    print("PASS: rules parse and the Alertmanager config, including its template file, is valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
