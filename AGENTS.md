# Agent notes

Use `master` as the branch name, never `main`.

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
- `docs/release-notes/macos-<version>.md`: required. The macOS release workflow
  stops without it on every push to `master`. Follow `macos-2.6.0.md`: what
  changed for Mac, requirements (macOS 13, a USB NFC / CCID reader), and the
  download and checksum.
- `docs/release-notes/android-<version>.md`: optional GitHub release text for
  the Android APK. Without it, all four languages of the store notes are used.
  The APK is Google Play's own signed build, so it installs over a Play
  install and the reverse.

Write for people using the app: describe what they can now do or what was
fixed, by card and city. Leave out internal names, commit hashes, card
numbers, raw card data, endpoints and credentials.

Pushing a new version to `master` publishes the macOS release automatically,
and the Android release once Google Play internal has that version, so commit
the notes before or with the version bump.
