# OKICA default card face

The bundled image is `CardBal/Assets.xcassets/okica.imageset/okica.png`:
796 × 500 pixels, an indexed PNG with 32 colors. The `OKICA` preset applies
automatically when scanning a card, and previously saved OKICA cards with an
untouched default appearance receive it on launch. Existing custom images and
explicitly disabled images are preserved during that upgrade.

The artwork is an adapted illustration, not an exact reproduction of a physical
card. Its yellow field, decorative waves, flowers, and mascots reference the
[OKICA card design](https://jamfunk.jp/ic/OKICA). The operator provides
[card-type information and sample faces](https://info.okica.jp/kinds.html).
Corner branding is omitted so the app can draw its own card title and balance.

Generated with the built-in image-generation tool, resized to 796 × 500 with
ImageMagick, and quantized with `pngquant --nofs --speed 1 --quality 0-100 32`.

## Generation prompt

Use case: precise-object-edit. Asset type: default OKICA card face background
for an iOS transit-card wallet, landscape aspect ratio 796:500. Edit target:
the supplied photographed OKICA card. Extract and restore only the printed
card face, perfectly flat, front-on and edge-to-edge, excluding all graph-paper
surroundings, physical border, corner rounding, wear, scan artifacts and shadows.
Preserve its large clean warm yellow field, the sweeping orange/yellow curve
toward the right, delicate white decorative wave pattern, and the narrow
light-blue floral strip at the right with the two small Okinawan mascots in
their existing positions. Remove the red OKICA sunburst logo, its lettering,
and all other printed text from the upper-right area, replacing only that area
with the adjacent pale blue/white background; no logos or text anywhere.
Preserve the reference's composition and cheerful yellow, orange, coral,
turquoise, soft green palette. Keep the left 65 percent open and plain for app
text overlays. Render as crisp clean flat printed vector-like illustration,
with clean smooth outlines and simple colors suited to reduction to a 32-color
indexed PNG, minimal gradients, no dithering or texture. Output one full
rectangular card background only, no mockup or surrounding canvas.
