# EZLink card preset

The preset uses the regular white EZ-Link card with the diagonal blue and green
EZ-Link logo pattern, as shown in the operator's own comparison artwork. It
replaces the generated Singapore skyline illustration.

Source page: [SimplyGo Cards & Charms](https://www.simplygo.com.sg/ezlink/ez-link-simplygo-ez-link-cards-charms/cards-charms/).

Source image: [SimplyGo EZ-Link comparison at a glance](https://www.simplygo.com.sg/media/fzmjnsci/simplygo-ezlink-comparison-at-a-glance.jpg),
accessed 31 October 2026. The left-hand card is labelled EZ-Link card; the
right-hand blue card is the separate SimplyGo EZ-Link product.

Source SHA-256: `c814645fe9f5b17aa9558961515b824507d14487b188e9d845437ee59c564db9`.

The bundled asset is `ios/CardBal/Resources/Presets/ezlink.png`: **512 x 323,
16-color indexed PNG, 38,357 bytes (37.5 KiB)**. The full comparison sheet is
not bundled. The printed logo, repeating pattern and layout come from the real
card artwork; no image generation or invented illustration is used.

Preparation: crop the 1107 x 1960 source to `(169, 60, 486, 260)`, isolate the
rounded card from the surrounding comparison-sheet shadow on white, resize
with Lanczos, quantize to 16 colors with median cut and no dithering, and save
with PNG optimization and level-9 compression. The standard preset name stays
`ezlink`, so cards already using it receive the corrected face automatically.
Custom card photos are unaffected.

The card design and EZ-Link marks belong to their respective owners. The
artwork identifies the supported card; authorship or official endorsement is
not claimed.
