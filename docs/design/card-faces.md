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

Both platforms offer the published defaults and alternates in a horizontal
appearance picker. After the color option, designs for the physical card's type
come first, followed by other cards for the same city in the same country.
City matches use the catalog's city codes or nonempty localized city names.
The card's current artwork does not affect this order: a Shanghai card wearing
Suica artwork still offers Shanghai designs first. The current unrelated face
and saved photos follow the matching presets, then the rest of the collection.
Opening the picker preserves the current selection, including color-only mode.
It hides duplicate bundled tiles once those designs are in the catalog.
The Korean collection offers five researched T-money physical designs in
addition to its existing two backgrounds, and five EZL/Cashbee designs including
the yellow default. Research references and the visual preview live in the
artwork repository.

Default artwork prefers no text, with an exception for lettering used as
decoration, such as PASMO's train and bus motif. Ordinary names, service labels,
numbers and small print remain in the text alternatives. PASMO also offers its
fully cleaned face as `no-text.png`; existing explicit text selections keep
working. The bundled PASMO fallback matches the decorative default.
