"""Fail if the registry's embedded config.json is not strict JSON.

zot parses /etc/zot/config.json with a strict JSON parser. In the manifest that value is a
YAML scalar holding the JSON, and comments *around* it are YAML comments that never reach the
value - so a "#" placed inside it makes zot exit at startup with

    While parsing config: invalid character '#' looking for beginning of object key string

`kustomize build` cannot catch that: a string with a stray "#" in it is still valid YAML.

Usage: check_config_json.py [root]   (root defaults to home-cluster, for testing the failure path)
"""

import json
import os
import sys

import yaml

MANIFEST = os.path.join("registry", "configmap.yaml")
CONFIG_KEY = "config.json"
VALUE_MARKERS = ('|', '>', '"', "'")


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "home-cluster"
    path = os.path.join(root, MANIFEST)
    if not os.path.exists(path):
        print("FAIL %s not found" % path)
        return 1

    checked = 0
    failed = False
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "ConfigMap":
            continue
        value = (doc.get("data") or {}).get(CONFIG_KEY)
        if value is None:
            continue
        checked += 1
        try:
            json.loads(value)
            print("OK   %s: %s parses as strict JSON" % (path, CONFIG_KEY))
        except Exception as exc:
            failed = True
            print("FAIL %s: %s is not valid JSON: %s" % (path, CONFIG_KEY, exc))

    if checked == 0:
        print("FAIL %s carries no %s value to check" % (path, CONFIG_KEY))
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
