# README artwork

The English, Japanese and Simplified Chinese READMEs share two promotional
illustrations:

- [CardBal introduction](../images/cardbal-hero.png): project name, tagline
  and supported platforms.
- [Cards, balances and journeys](../images/cardbal-journeys.png): saved transit
  cards, contactless reading and a schematic journey.

Both are 1774 × 887 PNGs with opaque backgrounds. They are illustrations;
they contain no app screenshots or personal card data.

## Generating replacements

Use the public [app splash artwork](../../android/app/src/main/res/drawable-nodpi/splash_cardbal.png)
as the style reference: warm ivory, teal, coral and lime, rounded transit cards,
raised route lines and soft shadows. Keep readable text brief, avoid numeric
balances and real station names, and preserve the actual platform requirements
in the README text.

The images use the built-in image-generation tool with the following prompts.
Save replacements in `docs/images/`, check the text and composition at README
width, and update the relative image paths and translated alt text in all three
READMEs together.

### Introduction prompt

```text
Use case: ads-marketing. Asset type: wide GitHub README hero, approximately 1536x768 landscape. Primary request: a polished CardBal transit-card-reader introduction banner. Reference: public existing CardBal app splash art, keep its warm ivory background, teal front transit card with tiny cream train symbol and contactless arcs, coral/lime/dark secondary cards, tactile layered-paper/soft ceramic material and gently raised map lines. Use the supplied local image only as a style/identity reference; generate a fresh illustration, not an edit of the source image. Composition: spacious editorial product illustration, large clear typography on the left and a beautiful stack of three transit cards on the right, a few simple transit lines flowing behind the stack. Calm, restrained, premium, very legible at GitHub width. Exact text only: "CardBal" in large dark-teal sans-serif, then "Your transit cards, together." in smaller sans-serif, and a small final line "iPhone · iPad · Mac · Android". Do not reproduce app screens, numbers, real station names, third-party logos, QR codes or credit-card chips. Card silhouettes are landscape transit cards. No badges, no download buttons, no extra copy, no watermarks. This is an illustration, not a screenshot. Opaque background. Generate exactly one image.
```

### Features prompt

```text
Use case: ads-marketing. Asset type: wide companion feature illustration for CardBal GitHub README, approximately 1536x768 landscape. Input image: the supplied local CardBal splash image is an identity and style reference only; generate a fresh composition. Primary request: a polished minimal promotional banner about saving transit cards, checking balances, and viewing mapped journeys. Match the public CardBal splash reference: warm ivory backdrop, rich teal, coral and spring lime accents, tactile layered paper / soft ceramic modeling, subtle soft shadows. Layout: balanced editorial composition with exact heading "Cards. Balances. Journeys." centered near top in clear dark-teal sans-serif. Below it, three spacious illustrated objects arranged along a single smoothly curving transit route: left a landscape teal transit card with tiny cream train/contactless symbols and coral/lime cards tucked behind, middle a softly raised rounded tile with an elegant contactless scanning symbol above a simple circular balance gauge (no numbers, no currency), right a compact schematic journey map on a rounded square tile with teal route, coral end marker and cream station dots. Connect the three objects gently through the background. Highly legible, sophisticated, visually harmonious and uncluttered. This is an illustrative feature graphic, no app screenshot or device frame; no real station names, map geography, card numbers, third-party logos, chips, QR codes, claims, badges, or extra copy. Only text is the specified heading. Opaque background.
```
