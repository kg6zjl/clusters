#!/usr/bin/env python3
import os
import sys

hops = int(sys.argv[1])

taco_bot_map = {
    "banana": "🍌",
    "taco": "🌮",
    "burger": "🍔",
}

if len(sys.argv) > 2:
    trigger = sys.argv[2]
else:
    trigger = os.environ.get("MESSAGE", "banana")

trigger = trigger.strip().lower().split()[0]
emoji = taco_bot_map.get(trigger, "🍌")

response = "❌" + emoji if hops == 0 else emoji * hops

print(response)