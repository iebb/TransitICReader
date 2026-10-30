package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.StoredValueProtocol
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

class ClipperWalletUpgradeTest {
    @Test fun rescanKeepsExistingWalletIdentityAndMergesLegacyHistory() {
        val old = TransitCardSnapshot(
            technology = "DESFire", cardFamily = "Clipper", identifierLabel = "UID",
            identifierValue = "04010203040506", rawIdentifierValue = "04010203040506",
            realSerialNumber = "12345678", scannedAt = Instant.fromEpochSeconds(1_800_000_000),
        )
        val current = old.copy(technology = "ISO7816", selectedAID = "9011F2")
        assertEquals(old.storageIdentifier, current.storageIdentifier)
        assertEquals(0, cardIndexForSnapshot(listOf(SavedCardRecord.from(old)), current))

        val payload = ByteArray(32) { 0x11 }
        val legacy = StoredValueProtocol.envelope(5, 3, 7, payload)
        val canonical = "0E" + "11".repeat(32)
        assertEquals(listOf(canonical), mergeCardHistory("Clipper", listOf(legacy), listOf(canonical)))
        val unknown = "ABCD"
        assertEquals(setOf(canonical, unknown),
            mergeCardHistory("Clipper", listOf(legacy, unknown), listOf(canonical)).toSet())
    }
}
