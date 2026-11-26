#!/usr/bin/env python3
"""Legacy entry point. The GUI and the agent API both go through monitor_play.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from monitor_play import main

if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0].startswith("["):
        args = ["api", "apply", *args]
    elif args and args[0] != "api":
        args = ["api", *args]
    raise SystemExit(main(args))
