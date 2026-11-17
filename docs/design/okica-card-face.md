# OKICA default card face

The image downloads as `faces/jp/okica/default.png` from
`https://faces.cardb.al/` and is stored as `remote.jp.okica.default.png`.
The shared repository normalizes it to 30:19 and at most 24 colors under
40,000 bytes. New OKICA cards
use this remote default, and old `okica` selections resolve to it. Existing
custom images and explicitly disabled images are preserved.

The artwork is an adapted illustration, not an exact reproduction of a physical
card. Its yellow field, decorative waves, flowers, and mascots reference the
[OKICA card design](https://jamfunk.jp/ic/OKICA). The operator provides
[card-type information and sample faces](https://info.okica.jp/kinds.html).
Corner branding is omitted so the app can draw its own card title and balance.

The source illustration was generated and prepared as a flat card background.
Maintain the yellow field, decorative waves and floral/mascot strip, with the
left side open for the app's text overlays. Follow the shared
[card-face requirements](card-faces.md) when preparing replacements.
