#!/usr/bin/env python3
import os
import sys

hops = int(sys.argv[1])

taco_bot_map = {
    "banana": "🍌",
    "taco": "🌮",
    "burger": "🍔",
    "pizza": "🍕",
    "cheese": "🧀",
    "hotdog": "🌭",
    "corn": "🌽",
    "burrito": "🌯",
}

if len(sys.argv) > 2:
    trigger = sys.argv[2]
else:
    trigger = os.environ.get("MESSAGE", "banana")

# Extract the first word, cleaned
trigger = trigger.strip().lower().split()[0]

# Safely exit if the word is not a valid option
if trigger not in taco_bot_map:
    sys.exit(0)

emoji = taco_bot_map[trigger]
response = "❌" + emoji if hops == 0 else emoji * hops

print(response)
