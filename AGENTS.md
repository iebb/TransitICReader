# Agent notes

Use `master` as the branch name, never `main`.

## Documentation

Keep documentation focused on current behavior, protocol facts, source
attribution and repeatable guides. Update the owning reference instead of
adding dated work logs, implementation reports or superseded surveys.
Keep the documentation index in `docs/README.md` current when moving pages.
Release notes are publishing inputs and follow the requirements below.

## Release notes

Every user-visible change needs release notes, and a version bump is not
complete without them. Add or update the notes in the same commit, for the
version that will ship the change (the one after the latest `android-v*` or
`macos-v*` release tag). See [releases](docs/development/releases.md) for how
the workflows use these files.

- `docs/release-notes/<version>.json`: App Store and Google Play "What's New".
  A JSON object with `en-GB`, `ja`, `ko` and `zh-Hans`, each a nonempty string
  of `• ` bullet lines joined by `\n`, as in `2.6.0.json`. Google Play receives
  only `en-GB`, so keep that text within Play's 500 characters.
- `docs/release-notes/macos-<version>.md`: required. The release workflow's
  macOS plan fails without it on every push to `master`. Follow `macos-2.6.0.md`: what
  changed for Mac, requirements (macOS 13, a USB NFC / CCID reader), and the
  download and checksum.
- `docs/release-notes/android-<version>.md`: optional GitHub release text for
  the Android APK. Without it, all four languages of the store notes are used.
  The release has Google Play's own signed APK, which installs over a Play
  install and the reverse, and a git-signed APK built in CI as
  `ad.neko.cardbal.android.gs`, which installs beside it. The workflow appends
  a note explaining the two, so don't repeat it.

Write for people using the app: describe what they can now do or what was
fixed, by card and city. Leave out internal names, commit hashes, card
numbers, raw card data, endpoints and credentials.

Pushing a new version to `master` publishes the macOS release automatically,
and the Android release once Google Play internal has that version, so commit
the notes before or with the version bump.
