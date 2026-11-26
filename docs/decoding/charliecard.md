# CharlieCard (Boston)

The CharlieCard of the Massachusetts Bay Transportation Authority (MBTA) in
Boston is a MIFARE Classic 1K card. Its sectors are protected with Crypto1
keys, but those keys are public: they ship in the Proxmark3 and Metrodroid
dictionaries. CardBal bundles them to read the card and authenticates for
reading only — it never writes a block. The implementation is adapted from
[Metrodroid](https://github.com/metrodroid/metrodroid)'s CharlieCard reader.

No physical CharlieCard has been read for this documentation; the layout and
keys are taken from Metrodroid. Verify against a card before relying on it.

## Reading a MIFARE Classic card

Built-in iPhone NFC cannot read a CharlieCard: Core NFC exposes no Crypto1
authentication or Classic sector access. The card is read only through an
external ACR122U-class reader (iPhone, iPad or Mac) and through Android NFC on
devices whose controller supports MIFARE Classic (`MifareClassic`, an NXP
feature). The App Clip, which is built-in NFC only, does not include it.

- **External reader.** The ACR122U PC/SC storage commands load a key into
  slot 0 (`FF 82 00 00 06`), authenticate a block (`FF 86 00 00 05 01 00 <block>
  <60=A|61=B> 00`) and read it (`FF B0 00 <block> 10`).
- **Android.** `MifareClassic.authenticateSectorWithKeyA/B` then
  `readBlock(sectorToBlock(sector) + n)`.

Sector 0 is authenticated with the two known CharlieCard sector-0 keys first
(`3060206F5B0A` and `F1B9F5669CC8`). Metrodroid identifies the card when either
key opens sector 0 as key A or key B, so CardBal tries both keys in both roles;
a card that refuses all four is not a CharlieCard and nothing else is tried.
Each remaining sector is opened by trying the public key pool as key A then key
B. The debug log records a refused sector 0 or any required sector that stays
closed.

## Layout

Only data blocks are read; sector trailers are not. All multi-byte fields are
big-endian.

- **Serial** — sector 0, block 0, bytes 0–3. Displayed as `5-<decimal>`.
- **Balance sector** — sector 2 or 3, whichever block 0 holds the larger
  16-bit transaction counter (bits 81–96).
  - **Balance** — balance sector block 1, bytes 5–6. Bit `0x8000` marks a
    negative value; the remainder, halved, is whole US cents.
  - **Issue date** — balance sector block 0, bytes 6–8, minutes since the
    epoch.
- **Trips** — sectors 6 and 7, up to twelve 7-byte records
  `[timestamp(3)][validator(2)][fare(2)]`. The validator's low three bits are
  the mode (0 ticket machine, 1 bus, otherwise subway); the rest is a validator
  id. The fare uses the same signed half-cent encoding as the balance.
- **Second card number** — sector 8, block 0, bytes 0–3; shown as
  `A<10 digits>` when present.

The epoch is `2003-01-01 00:00` Boston local time; timestamps are minutes and
are shown in `America/New_York`. A card expires eleven years after issue, less
a day, or two years after its last trip if that is earlier.

## Keys policy

CharlieCard is the first card for which CardBal bundles card keys. They are the
public MBTA transit keys and are used for reading only; the no-writing
discipline is unchanged. See [capabilities](capabilities.md) and
[card readers](../development/card-readers.md).

The CharlieCard adaptation retains Metrodroid's GPL-3.0-or-later notice; see
[`docs/licenses/FareBot-GPL-3.0.txt`](../licenses/FareBot-GPL-3.0.txt).
