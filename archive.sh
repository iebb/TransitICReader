#!/bin/bash
BUNDLE_ID="ad.neko.cardbal"
TEAM_ID="9733K94JUG"

echo "🎯 Archiving..."
xcodebuild archive \
  -project CardBal.xcodeproj \
  -scheme CardBal \
  -archivePath CardBal.xcarchive \
  -destination "generic/platform=iOS" \
  DEVELOPMENT_TEAM=$TEAM_ID \
  -allowProvisioningUpdates || exit 1

echo "✅ Archive completed: CardBal.xcarchive"
