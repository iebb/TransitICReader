# CEPAS stored-value purse and history

Both apps independently implement the public purse-3 protocol for every
structurally valid purse. The CAN names the card only where it is certain:
EZ-Link (prefix 100), NETS FlashPay (111) and Concession (8000–8009); any other
purse is labelled CEPAS without a brand guess. These other prefixes are
untested on real cards.
A complete purse response, valid BCD CAN and successful status are required.
Selecting an AID or recognizing a chip alone is insufficient. SimplyGo backend
account balances are not queried or inferred.

The read flow selects file 4000 with `00A40000024000`, then sends GET PURSE
`9032030000`, matching CoreExtendedNFC's CEPAS reader and FareBot/Metrodroid's
GET PURSE. Some 2012 EZ-Link cards return `6700` (wrong length) to that form on
purse 3 and `6B00` on every other purse. A purse that answers exactly `6700` is
asked again with the legacy six-byte form `903203000000` (CoreExtendedNFC notes
that some legacy cards need it), then as `90320300010000` (Lc 1, data `00`, Le
`00`). The first form that returns `9000` or `6B00` is used for the remaining
purses. The Swift ISO 7816 path (Core NFC and external readers) cannot express
the six-byte form, and the raw MIFARE path may be refused locally; either way it
is skipped with a log line, never treated as a lost card. Answers pass the same
structural checks; the log gets status words and lengths only. GET HISTORY is
`9032030001<offset><Le>`, with at most 15 records per request and Le set to the
requested record count times 16. Requests support one corrected-Le retry and
bounded `61xx` response chaining; final status must be exactly `9000`. The SELECT
command has no Le, so a `6Cxx` response cannot overwrite its file identifier. Partial,
malformed or protected data does not become a successful response. Optional
history failure preserves an already validated purse. iPhone supports the
ISO7816 and raw MIFARE discovery paths; Android uses ISO-DEP.

CEPAS cards are ISO 14443 Type B and do not implement ISO 7816-4 AID
selection properly, so Core NFC only hands one to the app after a listed AID
SELECT is accepted. The iOS app lists `A000000341000101` and
`00000000000000` at the end of its select identifiers, following
CoreExtendedNFC's example. Which identifier a particular card accepts must be
verified on that card; neither identifier establishes the issuer.

Purse and history amounts are signed 24-bit SGD cents. History timestamps are
unsigned seconds from 1995-01-01 midnight Singapore, Unix 788889600. The checked
FareBot revision's numeric epoch constant disagrees with its stated local
epoch by eight hours; the implementation and tests use the local Singapore
boundary confirmed by Metrodroid's timezone-aware epoch. Record kinds include
MRT, bus, purchase, reload, refund, service charge and card creation. Creation
records do not imply a monetary charge. Printable user data stays an original
label; it is not treated as a verified station or route identifier.

The portable raw envelope is `43 45 50 01 03` followed by the exact 16-byte log
record. Ring-buffer position is excluded. Both platforms retain the same
21-byte envelopes in backups and decode them before generic ISO histories.

Primary evidence:

- [FareBot purse fields](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/cepas/src/commonMain/kotlin/com/codebutler/farebot/card/cepas/CEPASPurse.kt)
  and [history fields](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/cepas/src/commonMain/kotlin/com/codebutler/farebot/card/cepas/CEPASHistory.kt).
- [Metrodroid's Singapore epoch](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/ezlink/EZLinkTransitData.kt).
- [NETS issuer instructions for iPhone/Android NFC balance/history reading](https://www.nets.com.sg/nets/for-you/nets-flashpay).
- [CoreExtendedNFC CEPAS selection and history requests](https://github.com/Lakr233/CoreExtendedNFC/blob/main/Sources/CoreExtendedNFC/Cards/Transit/Singapore/CEPASReader.swift).

Production Swift/Kotlin helpers are tested with invented purse/log bytes,
signed amounts, the Singapore-midnight epoch, invalid lengths/status words,
selection-dependent purse reads, bounded history pages, retry/chaining and
missing optional history. Swift regressions exercise ISO7816, raw MIFARE and
the external ISO reader transport. No upstream GPL implementation,
artwork, issuer keys or personal captures are included. Native Core NFC API
checking and app builds are separate from physical-card validation. An EZ-Link
CEPAS v2 card has been read through the Mac ACR122U path; this does not establish
all CEPAS prefixes or built-in iPhone discovery. See
[external readers](../development/external-nfc-readers.md).
