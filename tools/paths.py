"""Repository-owned inputs and generated station output locations."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS_APP = ROOT / "ios/CardBal"
IOS_RESOURCES = IOS_APP / "Resources"
ANDROID_ASSETS = ROOT / "android/app/src/main/assets"
PORTABLE_OUTPUT = ROOT / "build/stations"
BOUNDARIES = ROOT / "data/boundaries"
MAINTENANCE = ROOT / "data/maintenance"
CSV_LOCK = ROOT / "data/stations/card-stations.lock.json"
