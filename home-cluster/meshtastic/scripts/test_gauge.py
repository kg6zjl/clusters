#!/usr/bin/env python3
"""Gauge whether a MediumFast post carries genuine "I'm testing" intent.

Prints a redirect to the Test channel when the message signals real test intent
("afternoon test", "new antenna test") and ignores joke/mocking posts
("testicals", "testicular test") that merely contain the substring "test".

Invoked by MeshMonitor's automation engine from /data/scripts/. The message comes
from the MESSAGE env var that MeshMonitor sets. Word lists are overridable via
CLI args so they can be tuned without touching the script.

Usage:
  test_gauge.py [--test-words a,b] [--clown-words c,d]

Word-list format: comma-separated tokens. A trailing "*" on a token enables
prefix matching, e.g. --clown-words "testic*,testes" keeps the arg short.
Defaults are baked in and used when the flags are omitted.
"""

import argparse
import os
import re
import sys

DEFAULT_TEST_WORDS = "test,testing,online,qq,ping"
DEFAULT_CLOWN_WORDS = (
    "testic*,testes,cock"
)
DEFAULT_MAX_WORDS = 3

PUNCT = ".,!?;:'\"()[]{}<> \t\n"


def _parse_matchers(values: str):
    """Parse comma-separated matchers into (base, is_prefix) tuples."""
    matchers = []
    for raw in values.split(","):
        token = raw.strip().lower()
        if not token:
            continue
        if token.endswith("*"):
            matchers.append((token[:-1], True))
        else:
            matchers.append((token, False))
    return matchers


def _strip_punct(token: str) -> str:
    return token.strip(PUNCT).lower()


def is_genuine_test(text: str, test_words, clown_words, max_words: int = DEFAULT_MAX_WORDS) -> bool:
    """Return True if text signals genuine "I'm testing" intent and is not a joke."""
    tokens = [t for t in re.split(r"\s+", text.strip()) if t]
    if len(tokens) > max_words:
        return False
    if not any(_strip_punct(t) in test_words for t in tokens):
        return False
    for t in tokens:
        word = _strip_punct(t)
        for base, is_prefix in clown_words:
            if word.startswith(base) if is_prefix else word == base:
                return False
    return True

parser = argparse.ArgumentParser(
    description="Gauge Meshtastic message for genuine test intent.",
    add_help=False,
)
parser.add_argument("--test-words", default=DEFAULT_TEST_WORDS)
parser.add_argument("--clown-words", default=DEFAULT_CLOWN_WORDS)
parser.add_argument("--max-words", type=int, default=DEFAULT_MAX_WORDS)
args, _ = parser.parse_known_args()

text = os.environ.get("MESSAGE", "").strip().lower()

test_words = set(t.strip().lower() for t in args.test_words.split(",") if t.strip())
clown_words = _parse_matchers(args.clown_words)

if is_genuine_test(text, test_words, clown_words, max_words=args.max_words):
    print(1)
else:
    print(0)
sys.exit(0)
