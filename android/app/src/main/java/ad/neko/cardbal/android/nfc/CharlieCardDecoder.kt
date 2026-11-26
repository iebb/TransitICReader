// SPDX-License-Identifier: GPL-3.0-or-later
// CharlieCard reader adapted from Metrodroid. See docs/decoding/charliecard.md.
package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.MifareClassic
import ad.neko.cardbal.android.data.TransitCardSnapshot
import kotlinx.datetime.Instant

/**
 * Reads a Boston CharlieCard over `MifareClassic`. Sector 0 is authenticated
 * with the public CharlieCard key first; a card that refuses it is not a
 * CharlieCard. Every other sector is opened by trying the public key pool.
 * Only `readBlock` is used; no block is ever written.
 */
class CharlieCardDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = MifareClassic.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val card = MifareClassic.get(tag) ?: return null
        return card.use { mfc ->
            mfc.connect()
            if (authenticate(mfc, 0) == null) return@use null
            val sectors = mutableMapOf<Int, List<ByteArray>>()
            for (sector in CharlieCardProtocol.REQUIRED_SECTORS) {
                if (sector >= mfc.sectorCount) { if (sector == 0) return@use null else continue }
                if (authenticate(mfc, sector) == null) { if (sector == 0) return@use null else continue }
                val first = mfc.sectorToBlock(sector)
                sectors[sector] = (0 until 3).map { mfc.readBlock(first + it) }
            }
            CharlieCardProtocol.snapshot(sectors, tag.id, scannedAt)
        }
    }

    /** Try the public key pool as key A then key B. Sector 0 uses its two known keys. */
    private fun authenticate(mfc: MifareClassic, sector: Int): ByteArray? {
        if (sector == 0) {
            if (mfc.authenticateSectorWithKeyA(0, CharlieCardProtocol.SECTOR0_KEY_A)) return CharlieCardProtocol.SECTOR0_KEY_A
            return if (mfc.authenticateSectorWithKeyB(0, CharlieCardProtocol.SECTOR0_KEY_B)) CharlieCardProtocol.SECTOR0_KEY_B else null
        }
        for (key in CharlieCardProtocol.KEYS) if (mfc.authenticateSectorWithKeyA(sector, key)) return key
        for (key in CharlieCardProtocol.KEYS) if (mfc.authenticateSectorWithKeyB(sector, key)) return key
        return null
    }
}
