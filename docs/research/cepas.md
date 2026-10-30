# CEPAS stored-value purse and history

Both apps independently implement the public purse-3 protocol for positively
identified stored-value EZ-Link (CAN prefix100) and NETS FlashPay (111).
A complete purse response, valid BCD CAN and successful status are required.
Selecting an AID or recognizing a chip alone is insufficient. SimplyGo backend
account balances are not queried or inferred.

The implicit-application read commands are GET PURSE `9032030000` and GET
HISTORY `9032030001<offset>00`. Requests support one corrected-Le retry and
bounded `61xx` response chaining; final status must be exactly9000. Partial,
malformed or protected data does not become a successful response. Optional
history failure preserves an already validated purse. iPhone supports the
ISO7816 and raw MIFARE discovery paths; Android uses ISO-DEP.

Purse and history amounts are signed24-bit SGD cents. History timestamps are
unsigned seconds from1995-01-01 midnight Singapore, Unix788889600. The checked
FareBot revision's numeric epoch constant disagrees with its stated local
epoch by eight hours; the implementation and tests use the local Singapore
boundary confirmed by Metrodroid's timezone-aware epoch. Record kinds include
MRT, bus, purchase, reload, refund, service charge and card creation. Creation
records do not imply a monetary charge. Printable user data stays an original
label; it is not treated as a verified station or route identifier.

The portable raw envelope is `43 45 50 01 03` followed by the exact16-byte log
record. Ring-buffer position is excluded. Both platforms retain the same
21-byte envelopes in backups and decode them before generic ISO histories.

Primary evidence:

- [FareBot purse fields](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/cepas/src/commonMain/kotlin/com/codebutler/farebot/card/cepas/CEPASPurse.kt)
  and [history fields](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/cepas/src/commonMain/kotlin/com/codebutler/farebot/card/cepas/CEPASHistory.kt).
- [Metrodroid's Singapore epoch](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/ezlink/EZLinkTransitData.kt).
- [NETS issuer instructions for iPhone/Android NFC balance/history reading](https://www.nets.com.sg/nets/for-you/nets-flashpay).

Production Swift/Kotlin helpers are tested with invented purse/log bytes,
signed amounts, the Singapore-midnight epoch, invalid lengths/status words,
retry/chaining and missing optional history. No upstream GPL implementation,
artwork, issuer keys or personal captures are included. Native Core NFC API
checking and app builds are separate from physical-card validation, which is
still outstanding.
