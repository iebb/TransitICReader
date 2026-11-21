# Tarjeta Transporte Público (Madrid)

The Tarjeta Transporte Público of the Consorcio Regional de Transportes de
Madrid (CRTM) is a MIFARE DESFire EV1 card with application `000001`. Every file
in that application needs DESFire authentication with keys held only by CRTM, so
no public file can be read offline. The official app (Mi Tarjeta Transporte) and
third-party readers all relay the card's commands through CRTM's card-reading
service; CardBal does the same on iPhone, Mac (external reader) and Android.
The App Clip does not include it.

## Detection

After the public DESFire stored-value layouts, the reader sends the wrapped
`SELECT APPLICATION 000001` (`90 5A 00 00 03 00 00 01 00`). Only a `91 00` reply
leads to an online read. Nothing is sent to the network for other cards, in
quick or local-only scans, or when **Settings > Privacy > Madrid Online** is off.
The switch defaults to on (`madridOnlineEnabled` on iOS, `madrid` preferences on
Android).

## Service exchange

Base URL `https://latsecu.comunidad.madrid/middlelat`, JSON over HTTPS:

1. `POST /midd/device/init/conn` with `{"language":"en","timezone":"Europe/Madrid"}`.
   Status `0000` opens a session; the `JSESSIONID` and load-balancer cookies are
   kept in a per-read cookie jar. Without them the service answers `MDD-001`.
2. `POST /device/front/CardReading` with `titleList` `COMMON`, `salePoint`
   `010201000005`, `updateCard` `false`, `commandType` `WRAPPED` and
   `opInspection` `false`.
3. While `status.code` is `0010`, the reply's `capdu` list holds hex DESFire
   wrapped commands. Each reply (data plus SW1 SW2, uppercase hex) goes back as
   `rapdu` in the next `CardReading` request.
4. `0000` or `0001` ends the read and carries `balance` and `titleList`. Any
   other status is reported as a service error.

### Relay guard

CardBal relays only read-type DESFire commands: CLA `90`, P1 = P2 = `00`, a final
Le `00`, and instruction `60 5A 0A 1A AA 71 77 BD BB 6C 6F 6A 6D 61 45 64 F5 51 6E`
(version, select, authenticate, read data/records/value and file, key and memory
information). `AF` (additional frame) is relayed only after a `91 AF` reply, and
that state carries over into the next round because authentication spans rounds.
Any other command, including writes, credit, debit and commit, ends the read
before it reaches the card. `updateCard` is always `false`.

Limits: 16 rounds, 64 commands per round, 256 KiB per response, 10 s per request,
30 s overall and no redirects.

## Fields

| Service field | Shown as |
| --- | --- |
| `balance.cardNumber` | Card Number (also the real serial number) |
| `orderCode`, `cardOrderNumber` | Card Number when `cardNumber` is `null`, as on a Tarjeta MULTI: printed as `MB0-12345678`, without `controlDigit` |
| `balance.desfireSerial` | Identifier (the 14-digit serial printed on a Tarjeta MULTI), falling back to the tag UID |
| `titleList.cardName` | Card Type |
| `balance.groupName` | Profile |
| `profiles[].profileName`, `finishProfileDate` | `<profile>` Valid Until, only when it differs from the card's expiry |
| `initAppDate`, `finishAppDate` | Issue Date, Expiry Date |
| `blockedApp` | Status = Blocked |
| `chargeState` `CADUCADO` on a ticket | `<ticket>` Status = Expired |
| `titTemp` | Pass: Ticket, Zones, Valid From, Valid Until, Sold At, Last Use |
| `titMV1` – `titMV3` | Multi-trip ticket: Ticket, Zones, Remaining Trips, Sold At, Last Use |

A pass is valid from `firstDateValCharge` (or `initChargeDate`) until
`finalDateValCharge` (or `finishChargeDate`). This reading of the first-use
window has not been confirmed with a physical card. Repeated ticket names are
numbered, for example `Metro (2)`. **Remaining Trips** appears at card level, and
on the card face, only when the card has no current pass and exactly one current
multi-trip ticket; expired tickets are ignored. Other `chargeState` values are
not interpreted. The card has no stored-value purse, so no balance is shown.

Dates written as `yyyy-MM-dd[ HH:mm[:ss]]` are Madrid local time (the service's
`now` matches Madrid's clock) and are kept as written, with a midnight time
dropped; values with an explicit offset are converted to Europe/Madrid, and
anything else is shown as returned.

Raw Data keeps a **CRTM Service** section with the final status, rounds, relayed
command count and the returned card and ticket objects, without the list of
titles on sale. The debug log records only the Madrid Online setting and the
exchange outline, not the card's replies.

## Privacy

With Madrid Online on, the card's DESFire replies, including its serial number,
are sent to CRTM while the card stays on the reader. CardBal sends no account
or device identifier. The service is undocumented and may change or refuse
third-party readers; a failed read is recorded in the debug log and the scan
continues with the remaining readers.

## Sources

- [CRTM-NFC/Mifare-Desfire](https://github.com/CRTM-NFC/Mifare-Desfire): card
  layout and key ownership.
- [luu176/CRTM](https://github.com/luu176/CRTM) (MIT): service endpoints and
  request bodies.
- [xBaank/MadridTransporte](https://github.com/xBaank/MadridTransporte)
  (GPL-3.0, front end at `bdae6f3`): consulted only for the meaning of the
  response fields; no code was copied.
- [Cómo funcionan los sistemas del transporte público](https://medium.com/@elroby444/como-funcionan-los-sistemas-del-transporte-publico-293ff340e351).

`tests/runtime/fixtures/madrid-ttp.json` holds invented service responses used
by the Swift and Android protocol tests. A Tarjeta MULTI with an expired
single-trip ticket has been read through the production Swift reader with an
ACR122U; personal cards, passes and Android NFC still need physical-card checks.
