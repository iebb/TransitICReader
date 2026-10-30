# EZLink artwork

The application bundles only `ios/CardBal/Resources/Presets/ezlink.png`:
768 × 484, indexed PNG, six used colors, 9,920 bytes (9.7 KiB). The full-resolution
image-generation originals are not part of the repository or release. The face
is applied to EZLink cards without an existing custom face; user artwork is
preserved. The preset also appears in card customization.

Generated using the built-in ImageGen tool. Prompt:

> Create one original, beautifully art-directed landscape transit-card face artwork for the EZLink card preset in an independent travel-card reader app. Flat screen-print / cut-paper graphic design, wide horizontal credit-card proportions about 1.586:1, full-bleed edge-to-edge rectangular image, no photographed card, no border, no rounded outside corners, no shadows outside the image. Exact only lettering: 'EZLink', clean white modern rounded sans-serif, modest size near upper right with generous padding. A sophisticated Singapore-inspired geometric skyline along the lower third, the recognizable three towers and boat-like roof silhouette of Marina Bay Sands, subtle palm silhouettes and a single flowing rail ribbon. Keep the upper left and middle spacious and calm for the app's title and balance overlay. Premium friendly travel aesthetic, restrained and graphic, bold large shapes and clean hard edges. Strictly limited flat palette of deep navy #102C49, saturated cyan #19B6CB, warm coral #F57D66, pale cream #FFF2D7, and white only. No gradients, no texture, no grain, no photographic detail, no fine hatching, no microtext, no card number, no chip, no flags, no word Singapore, no contactless logo, no payment-network logos, no official authenticity claims. Suitable for later indexed-PNG palette reduction with very small file size. Produce a single finished card artwork, not a sheet or mockup.

A second built-in ImageGen edit removed the baked-in title after checking the
card inside the app, so it cannot collide with the balance. Final edit prompt:

> Use case: precise-object-edit. Edit target: the provided landscape Singapore transit card artwork. Change only one thing: remove the white EZLink lettering in the upper right and fill its former area with the identical solid deep navy background #102C49. The entire image must contain NO text, lettering, numbers or logos. Preserve the original composition, full-bleed rectangle, dimensions/proportions, skyline, Marina Bay Sands silhouette, sun, water, clouds, train, palms, flat screen-print style and limited cyan/coral/cream/navy palette unchanged. Keep the upper third spacious, dark and blank because the app overlays the card title on the left and balance on the right. No new elements, no gradients, no texture or grain, no frame. Output just the edited card artwork.

Optimization: resize using Lanczos, quantize without dithering against the five
specified colors plus black, then save an indexed PNG with level-9 compression
and optimization enabled. This removes the original's texture and large color
space while preserving clean flat shapes and legibility. The artwork is an
original app preset, not a claim of official EZ-Link card issuance.
