#!/usr/bin/env python3
"""Compatibility entry point for Xcode, Android Gradle, and existing commands."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.stations.build import main

if __name__ == "__main__":
    main()
