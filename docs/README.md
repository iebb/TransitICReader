# Documentation

These pages describe the current application, supported formats and maintenance
procedures. Protocol sources and licence notices stay with the relevant
reference. Release notes are publishing inputs under `release-notes/`.

## Card decoding

- [Reader coverage, decoded fields and platform limits](decoding/capabilities.md)
- [Decoder pipeline and card formats](decoding/cards.md)
- [Local Shenzhen, Wuhan, Lingnan Pass and Beijing purses](decoding/china-local.md)
- [Shanghai City Union, T-Union and Octopus companion scans](decoding/shanghai.md)
- [Payment and gate-history correlation](decoding/journey-correlation.md)
- [Tianfu Tong CPU cards](decoding/tianfutong.md)
- [CEPAS purse and history](decoding/cepas.md)
- [DESFire stored-value layouts](decoding/desfire-stored-value.md)
- [Clipper cards and tickets](decoding/clipper.md)
- [Macau Pass](decoding/macau-pass.md)
- [Calypso public records](decoding/calypso.md)
- [Lisboa Viva / navegante Zapping](decoding/lisboa-zapping.md)

## Development

- [Build and test checks](development/testing.md)
- [Adding or changing a card reader](development/card-readers.md)
- [External NFC readers and Singapore maps](development/external-nfc-readers.md)
- [Simulator and emulator sample wallets](development/sample-data.md)
- [GitHub releases and store workflows](development/releases.md)
- [Station-report service](../services/station-reports/README.md)

## Data and artwork

- [Licences and credits](licenses/README.md)
- [Station catalog, compilation and attribution](data/station-assets.md)
- [Trip Reader station formats and backup import](data/tripreader.md)
- [UB Smart Bus data](data/ub-smart-bus.md)
- [Downloaded card faces](design/card-faces.md)
- [README artwork and generation prompts](design/readme-artwork.md)
- [EZ-Link artwork source and preparation](design/ezlink-artwork.md)
- [OKICA artwork and default selection](design/okica-card-face.md)

Third-party licence texts are in `licenses/`; source-specific attribution is
also recorded in the decoder and data references.
