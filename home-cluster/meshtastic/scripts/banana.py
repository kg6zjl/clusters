#!/usr/bin/env python3
import sys
import json

hops = int(sys.argv[1])
trigger = str(sys.argv[2]).lower()

taco_bot_map = {
    "banana": "🍌",
    "taco": "🌮",
    "burger": "🍔",
}

response = f"❌{ taco_bot_map[trigger] }" if hops == 0 else taco_bot_map[trigger] * hops

print(response)
