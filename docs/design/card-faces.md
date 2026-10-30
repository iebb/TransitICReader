# Downloaded card faces

iOS and Android prefer the shared collection at `https://faces.cardb.al/`.
Every default has a `default.png`; alternate designs live beside it and are
listed in the manifest. The collection is maintained in
[iebb/card-faces](https://github.com/iebb/card-faces) and Cloudflare Pages rebuilds
from `master` on push.

Only Suica, PASMO, ICOCA, T-money and EZL remain bundled as offline fallbacks.
The other regional, retail and specialty faces download when used. There is no
usage telemetry behind this selection. Duplicate iOS resource copies were also
removed. Every retained fallback is an indexed PNG under 40,000 bytes with at
most 24 colors.

The apps cache the manifest for a day and download individual PNGs on demand,
checking their byte count and SHA-256. Cached art works offline. A missing face
uses its retained bundle where available, otherwise the card's existing color
appearance. Fallbacks are not cached under remote tokens, so a pending download
can replace them. jsDelivr and raw GitHub mirror the same paths.

Old bundle identifiers, including the selected blue La Carte alternate, resolve
to their published tokens. iOS migrates those selections on launch/save and
after the catalog refresh; Android resolves them when rendering. Custom photos,
remote alternates and explicit color-only choices are preserved. Downloaded
files stay outside the backed-up custom-photo directory.

The picker includes all published defaults and alternates, with matching designs
first. It hides duplicate bundled tiles once those designs are in the catalog.
The Korean collection offers five researched T-money physical designs in
addition to its existing two backgrounds, and five EZL/Cashbee designs including
the yellow default. Research references and the visual preview live in the
artwork repository.
