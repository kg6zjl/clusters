#!/usr/bin/env python3
import sys
import json

hops = int(sys.argv[1])

response = "🐒" if hops == 0 else "🍌" * hops

print(response)