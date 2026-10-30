package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.data.TripReaderBackup.CITY_UNION_AID
import ad.neko.cardbal.android.data.TripReaderBackup.CardRow
import ad.neko.cardbal.android.data.TripReaderBackup.TransactionRow
import ad.neko.cardbal.android.data.TripReaderBackup.T_UNION_AID
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

/** Synthetic Trip Reader rows replayed through the production ISO 7816 reader. */
class TripReaderBackupTest {
    private val unknown = -99_999_999L
    // Issuer files: City Union in a non-Shanghai city (little-endian serial 123456789),
    // T-Union with its card number at bytes 10-20.
    private val cityUnionInfo = "00004510" + "00".repeat(12) + "15CD5B07" + "20230101" + "20331231" + "0000"
    private fun tUnionInfo(number: String) = "00001000" + "00".repeat(6) + number + "20240101" + "20341231" + "0000"

    private fun ledger(counter: Int, day: Int, type: String = "06") =
        "%04X".format(counter) + "000000" + "00000064" + type + "100000000001" + "202601%02d120000".format(day)
    private fun travel(day: Int) = "02" + "00".repeat(24) + "202601%02d130000".format(day) + "1000" + "00".repeat(14)

    private fun row(card: String, ledger: String, travel: String = "", sfi: Int = 0x18, cityUnion: Boolean = false,
                    tUnion: Boolean = false, hasTravel: Boolean = travel.isNotEmpty()) =
        TransactionRow(card, ledger, travel, sfi, cityUnion, tUnion, hasTravel)

    private fun backup(): List<TripReaderBackup.Card> {
        val cards = listOf(
            CardRow("DUAL", 1_790_000_000_000, isTUnion = true, isCityUnion = true, balance = 1084,
                cityUnionBalance = 1234, tUnionBalance = -150, cityUnionInfo = cityUnionInfo, tUnionInfo = tUnionInfo("3104100012345678901F")),
            CardRow("TUONLY", 1_790_000_000_000, isTUnion = true, isCityUnion = false, balance = 200,
                cityUnionBalance = unknown, tUnionBalance = unknown, cityUnionInfo = "", tUnionInfo = tUnionInfo("3104100099990000111F")),
            CardRow("BEIJING", 1_790_000_000_000, isTUnion = false, isCityUnion = false, balance = 500,
                cityUnionBalance = unknown, tUnionBalance = unknown, cityUnionInfo = "", tUnionInfo = ""),
        )
        val rows = (0 until 35).map { row("DUAL", ledger(it + 1, 1 + it % 28), cityUnion = true) } +
            (1..3).map { row("DUAL", ledger(100 + it, it), travel(it), tUnion = true) } +
            row("DUAL", ledger(200, 28), cityUnion = true, tUnion = true) +
            row("DUAL", ledger(201, 27, "02"), sfi = 0x10, cityUnion = true) +
            (1..5).map { row("TUONLY", ledger(it, it), if (it == 3) "" else travel(it), tUnion = true) } +
            row("BEIJING", ledger(1, 1), cityUnion = false, tUnion = false)
        return TripReaderBackup.cards(cards, rows)
    }

    @Test fun mapsApplicationsBalancesAndRecordOwnership() {
        val cards = backup().associateBy { it.rawNumber }
        val dual = cards.getValue("DUAL").applications
        assertEquals(1234L, dual.getValue(CITY_UNION_AID).balanceCents)
        assertEquals(-150L, dual.getValue(T_UNION_AID).balanceCents)
        // A dual-flagged ledger row belongs to City Union; top-ups keep their own file.
        assertEquals(36, dual.getValue(CITY_UNION_AID).records.getValue(0x18).size)
        assertEquals(1, dual.getValue(CITY_UNION_AID).records.getValue(0x10).size)
        assertEquals(3, dual.getValue(T_UNION_AID).records.getValue(0x18).size)
        assertEquals(3, dual.getValue(T_UNION_AID).records.getValue(0x1e).size)
        val single = cards.getValue("TUONLY").applications.getValue(T_UNION_AID)
        assertEquals(200L, single.balanceCents)
        assertEquals(4, single.records.getValue(0x1e).size)
        assertTrue(cards.getValue("BEIJING").applications.isEmpty())
    }

    @Test fun replaysCardsThroughTheProductionReaderWithFullHistory() {
        val plan = TripReaderBackup.importPlan(backup())
        assertEquals(2, plan.snapshots.size)
        assertEquals(1, plan.skippedCards)
        assertEquals(36 + 1 + 3 + 3 + 5 + 4, plan.recordCount)

        val dual = plan.snapshots.first { it.realSerialNumber == "3104100012345678901" }
        assertEquals("ISO7816|3104100012345678901", dual.storageIdentifier)
        val apps = dual.applications.orEmpty().associateBy { it.selectedAID }
        assertEquals("123456789", apps.getValue(CITY_UNION_AID).serialNumber)
        assertEquals(formatCardMoney(1234, "CNY", 2), apps.getValue(CITY_UNION_AID).balanceText)
        assertEquals(formatCardMoney(-150, "CNY", 2), apps.getValue(T_UNION_AID).balanceText)
        // More than the 30 records a card file holds, newest first.
        val cityRecords = apps.getValue(CITY_UNION_AID).records.filter { it.sfi == 0x18 }
        assertEquals(36, cityRecords.size)
        assertTrue(cityRecords.first().hex.endsWith("20260128120000"))
        assertEquals((1..36).toList(), cityRecords.map { it.index })
        assertEquals(37 + 6, dual.rawTransactions.size + dual.rawTransitHistory.size)
        assertEquals("", apps.getValue(T_UNION_AID).identifier)

        val single = plan.snapshots.first { it.realSerialNumber == "3104100099990000111" }
        assertEquals(formatCardMoney(200, "CNY", 2), single.balanceText)
        assertEquals(5, single.rawTransactions.size)
        assertEquals(4, single.rawTransitHistory.size)
        assertEquals(Instant.fromEpochMilliseconds(1_790_000_000_000), single.scannedAt)
    }

    @Test fun olderBackupAddsHistoryWithoutRollingBackTheBalance() {
        val imported = SavedCardRecord.from(TripReaderBackup.importPlan(backup()).snapshots
            .first { it.realSerialNumber == "3104100099990000111" })
        val app = imported.applications!!.single()
        val later = Instant.fromEpochMilliseconds(1_800_000_000_000)
        val localRecord = TransitApplicationRecord("transaction", 0x18, 1, ledger(9, 1))
        val local = imported.copy(
            id = "ISO7816|01020304", customTitle = "Commute", order = 3, scannedAt = later,
            applications = listOf(app.copy(identifier = "01020304", balanceText = "LOCAL", balanceReadAt = later,
                scannedAt = later, records = listOf(localRecord))),
        )
        assertTrue(local.sharesApplication(imported))
        val merged = local.mergingImported(imported)
        assertEquals("ISO7816|01020304", merged.id)
        assertEquals("Commute", merged.customTitle)
        assertEquals(3, merged.order)
        assertEquals("LOCAL", merged.balanceText)
        assertEquals(later, merged.scannedAt)
        assertEquals("01020304", merged.applications!!.single().identifier)
        assertEquals(10, merged.applications!!.single().records.size)

        // A newer backup reading replaces an older local one.
        val older = local.copy(scannedAt = Instant.fromEpochMilliseconds(0), applications = listOf(
            app.copy(identifier = "01020304", balanceText = "OLD", scannedAt = Instant.fromEpochMilliseconds(0))))
        val refreshed = older.mergingImported(imported)
        assertEquals(formatCardMoney(200, "CNY", 2), refreshed.balanceText)
        assertEquals("01020304", refreshed.applications!!.single().identifier)
    }
}
