CardBal is now available for macOS as a universal Mac Catalyst app for Apple
silicon and Intel Macs. The app is signed with Developer ID and notarized by
Apple.

Download `CardBal-2.5.2-macOS.zip`, open it, and move CardBal to Applications.
CardBal requires macOS 13 Ventura or later.
A compatible external USB NFC / CCID reader is required to scan cards on a Mac.
The ACR122U has been verified with Edy, EZLink and Tianfu Tong CPU cards.

This release includes:

- Shenzhen Tong, Wuhan Tong and Beijing Yikatong balance readers, with readable
  on-card payment and top-up history.
- Lisbon Zapping balance and readable Calypso transaction records.
- 284 Shenzhen metro terminal mappings and corrected Shanghai City Union naming.
- Hong Kong city recognition in T-Union history.
- Trip Reader backup imports and card-face preset, gallery and camera pickers.

Card support depends on the card generation and the reader. New Chinese local
and Lisbon decoding has synthetic regression coverage; physical-card validation
for those additions remains outstanding.

The repository and this tag include the application source, build instructions
and third-party code and data license notices. `SHA256SUMS.txt` contains the
download checksum.
