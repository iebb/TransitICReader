package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.ChineseHistoryMerge
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.data.formatCardMoney
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.TimeZone

/** Synthetic replies only; these do not substitute for RF testing on physical cards. */
class MacauPassDecoderTest {
    private val select = "00A404000AB0C4C3C5CDA8C7AEB0FC00"
    private val infoCommand = "00B0950000"
    private val balanceCommand = "805C000204"
    private val tUnionSelect = "00A4040008A00000063201010500"
    private val scannedAt = Instant.fromEpochSeconds(1_800_000_000)
    private val uid = "04DEADBEEF0102"

    private fun record(number: Int) = "00B2%02XC417".format(number)
    private fun uint32(value: Long) = (0..3).map { ((value shr ((3 - it) * 8)) and 0xFF).toByte() }.toByteArray()
    private fun info(serial: String = "12ABCDEF", issue: String = "20240229", expiry: String = "20320630") =
        ByteArray(16) { 0x55 } + serial.hexToBytes() + issue.hexToBytes() + expiry.hexToBytes()
    private fun transaction(sequence: Int = 0x8123, units: Long = 37, type: Int = 0x09,
                            timestamp: String = "20240229123456", terminal: String = "001234005678") =
        byteArrayOf((sequence shr 8).toByte(), sequence.toByte()) + "123456".hexToBytes() + uint32(units) +
            byteArrayOf(type.toByte()) + terminal.hexToBytes() + timestamp.hexToBytes()

    private class Reply(val command: String, val data: ByteArray = byteArrayOf(), val status: String = "9000", val fails: Boolean = false)

    /** Strict replay. Violations are recorded because the decoder swallows optional read errors. */
    private class Card(replies: List<Reply>) {
        private val queue = ArrayDeque(replies)
        private val violations = mutableListOf<String>()
        fun exchange(apdu: ByteArray): ByteArray {
            val command = apdu.hexString()
            val reply = queue.removeFirstOrNull()
            if (reply == null || reply.command != command) {
                violations.add("Expected ${reply?.command}, got $command")
                throw IOException("unexpected APDU")
            }
            if (reply.fails) throw IOException("tag lost")
            return reply.data + reply.status.hexToBytes()
        }
        fun assertComplete() {
            assertTrue(violations.toString(), violations.isEmpty())
            assertTrue("Unconsumed: ${queue.map { it.command }}", queue.isEmpty())
        }
    }

    private fun prefix(info: ByteArray = info(), balance: ByteArray = uint32(1234)) =
        listOf(Reply(select), Reply(infoCommand, info), Reply(balanceCommand, balance))
    // A plain Macau Pass card has no T-Union application.
    private val noCompanion = Reply(tUnionSelect, status = "6A82")
    private val end = Reply(record(1), status = "6A83")

    private fun read(replies: List<Reply>, uid: String = this.uid) =
        Card(replies).let { card -> MacauPassDecoder.read(uid, scannedAt, card::exchange).also { card.assertComplete() } }

    @Test fun readsExactCommandsAndSnapshot() {
        val debit = transaction()
        val credit = transaction(sequence = 0x8122, units = 500, type = 0x02)
        val snapshot = read(prefix() + listOf(Reply(record(1), debit), Reply(record(2), credit), Reply(record(3), status = "6A83"), noCompanion))!!
        assertEquals("Macau Pass", snapshot.cardFamily)
        assertEquals("ISO7816", snapshot.technology)
        assertEquals(MacauPassDecoder.APPLICATION_AID, snapshot.selectedAID)
        assertEquals("12ABCDEF", snapshot.identifierValue)
        assertEquals("12ABCDEF", snapshot.realSerialNumber)
        assertEquals(uid, snapshot.rawIdentifierValue)
        assertEquals(scannedAt, snapshot.scannedAt)
        assertEquals(formatCardMoney(11_340, "MOP", 2), snapshot.balanceText)
        assertEquals(listOf(debit.hexString(), credit.hexString()), snapshot.rawTransactions)
        val app = snapshot.applications!!.single()
        assertTrue(app.isMacauPass)
        assertEquals(listOf(1, 2), app.records.map { it.index })
        assertTrue(app.records.all { it.kind == "transaction" && it.sfi == 0x18 })
        assertTrue(snapshot.resultFields.any { it.title == "Issue Date" && it.value == "2024-02-29" })
        assertTrue(snapshot.resultFields.any { it.title == "Expiry Date" && it.value == "2032-06-30" })
    }

    @Test fun transactionsUseUnsignedTenthsAndIssuerClock() {
        val debit = MacauPassDecoder.decodeTransaction(transaction())!!
        assertEquals(-370L, debit.amount)
        assertEquals(2, debit.fractionDigits)
        assertEquals("MOP", debit.currencyCode)
        assertEquals("Asia/Macau", debit.issuerTimeZone)
        assertTrue(debit.amountIsSigned && debit.amountKnown)
        assertEquals(TransactionCategory.payment, debit.category)
        assertEquals(0x8123, debit.recordNumber)
        assertEquals("001234005678", debit.terminalID)
        assertEquals(transaction().hexString(), debit.rawData)
        assertNull(debit.balanceAfter)
        assertEquals("12:34:56", debit.time)
        assertEquals(1_709_181_296L, debit.date!!.epochSeconds)

        val credit = MacauPassDecoder.decodeTransaction(transaction(units = 500, type = 0x02))!!
        assertEquals(5_000L, credit.amount)
        assertEquals(TransactionCategory.topUp, credit.category)
        assertEquals(-370L, MacauPassDecoder.decodeTransaction(transaction(type = 0x06))!!.amount)
        assertEquals("0000ABCDEF98", MacauPassDecoder.decodeTransaction(transaction(terminal = "0000ABCDEF98"))!!.terminalID)
        for (units in listOf(0L, 1L, 0x01000001L, 0x80000000L, 0xFFFFFFFFL)) {
            val tx = MacauPassDecoder.decodeTransaction(transaction(sequence = 0xFFFF, units = units))!!
            assertEquals("All four amount bytes are unsigned: $units", -units * 10, tx.amount)
            assertEquals(65_535, tx.recordNumber)
        }
        val unknown = MacauPassDecoder.decodeTransaction(transaction(type = 0xFE))!!
        assertEquals(TransactionCategory.unknown, unknown.category)
        assertEquals(0L, unknown.amount)
        assertFalse(unknown.amountKnown)
        assertEquals("MOP", unknown.currencyCode)
    }

    @Test fun rejectsMalformedHistoryAndInvalidCalendarValues() {
        for (length in 0 until 23) assertNull(MacauPassDecoder.decodeTransaction(transaction().copyOf(length)))
        for (length in listOf(24, 25, 46, 256)) assertNull(MacauPassDecoder.decodeTransaction(transaction() + ByteArray(length - 23)))
        assertNull(MacauPassDecoder.decodeTransaction(ByteArray(23)))
        for (stamp in listOf("20230229123456", "21000229123456", "20240431123456", "20240001123456", "20241301123456",
                "20240100123456", "20240132123456", "20240229243456", "20240229126056", "20240229123460",
                "2024022912346A", "2024FA29123456", "00000000000000", "FFFFFFFFFFFFFF")) {
            assertNull(stamp, MacauPassDecoder.decodeTransaction(transaction(timestamp = stamp)))
        }
        for (offset in 16 until 23) {
            assertNull(MacauPassDecoder.decodeTransaction(transaction().also { it[offset] = 0x1A }))
        }
        val expected = mapOf("20240229123456" to 1_709_181_296L, "20000229000000" to 951_753_600L,
            "20251231235959" to 1_767_196_799L, "20260101000000" to 1_767_196_800L, "21000301000000" to 4_107_513_600L)
        val original = TimeZone.getDefault()
        try {
            for (zone in listOf("UTC", "America/Los_Angeles", "Asia/Tokyo")) {
                TimeZone.setDefault(TimeZone.getTimeZone(zone))
                for ((stamp, epoch) in expected) {
                    assertEquals("$stamp in $zone", epoch, MacauPassDecoder.decodeTransaction(transaction(timestamp = stamp))!!.date!!.epochSeconds)
                }
            }
        } finally {
            TimeZone.setDefault(original)
        }
        for (date in listOf("20230229", "21000229", "20240431", "20241301", "20240001", "20240100", "2024FA29", "00000000", "FFFFFFFF")) {
            val snapshot = read(prefix(info = info(issue = date, expiry = date)) + listOf(end, noCompanion))!!
            assertTrue(date, snapshot.resultFields.none { it.title == "Issue Date" || it.title == "Expiry Date" })
            assertEquals("12ABCDEF", snapshot.realSerialNumber)
            assertNotNull(snapshot.balanceText)
        }
    }

    @Test fun balanceExcludesReserveAndKeepsUnknownLayoutsRaw() {
        for (units in listOf(0L, 1L, 99L, 100L, 1234L, 0x7FFFFFFFL)) {
            val snapshot = read(prefix(balance = uint32(units)) + listOf(end, noCompanion))!!
            assertEquals(formatCardMoney(units * 10 - 1000, "MOP", 2), snapshot.balanceText)
        }
        for (units in listOf(0x80000000L, 0x80000001L, 0xFFFFFFFFL)) {
            val bytes = uint32(units)
            val snapshot = read(prefix(balance = bytes) + listOf(end, noCompanion))!!
            assertNull(snapshot.balanceText)
            assertTrue(snapshot.rawSections.flatMap { it.fields }.any { bytes.hexString() in it.value })
        }
        for (length in listOf(0, 1, 2, 3, 5, 6, 8)) {
            val snapshot = read(prefix(balance = ByteArray(length) { 1 }) + listOf(end, noCompanion))!!
            assertNull(snapshot.balanceText)
            assertEquals("12ABCDEF", snapshot.realSerialNumber)
        }
    }

    @Test fun optionalReadsFailIndependentlyAndUselessScansAreRejected() {
        for (status in listOf("9001", "6A82", "6982", "6A83", "6F00", "6300")) {
            // A failed SELECT issues no file read and no companion probe.
            assertNull(read(listOf(Reply(select, status = status))))
            val noInfo = read(listOf(Reply(select), Reply(infoCommand, info(), status), Reply(balanceCommand, uint32(1234)), end, noCompanion))!!
            assertNull(noInfo.realSerialNumber)
            assertNotNull(noInfo.balanceText)
            val noBalance = read(listOf(Reply(select), Reply(infoCommand, info()), Reply(balanceCommand, uint32(1234), status),
                Reply(record(1), transaction()), Reply(record(2), status = "6A83"), noCompanion))!!
            assertNull(noBalance.balanceText)
            assertEquals(1, noBalance.rawTransactions.size)
            val noHistory = read(prefix() + listOf(Reply(record(1), transaction(), status), noCompanion))!!
            assertTrue(noHistory.rawTransactions.isEmpty())
            assertNotNull(noHistory.balanceText)
        }
        val historyOnly = read(listOf(Reply(select), Reply(infoCommand, status = "6A82"), Reply(balanceCommand, status = "6982"),
            Reply(record(1), transaction()), Reply(record(2), status = "6A83"), noCompanion))!!
        assertNull(historyOnly.balanceText)
        assertEquals(1, historyOnly.rawTransactions.size)
        // Raw-only or empty responses do not manufacture a card, and skip the companion probe.
        assertNull(read(listOf(Reply(select), Reply(infoCommand, status = "6A82"), Reply(balanceCommand, status = "6982"), end)))
        assertNull(read(listOf(Reply(select), Reply(infoCommand), Reply(balanceCommand), Reply(record(1)))))
        val invalid = transaction(timestamp = "20230229123456")
        assertNull(read(listOf(Reply(select), Reply(infoCommand), Reply(balanceCommand), Reply(record(1), invalid), Reply(record(2), status = "6A83"))))
        assertNull(read(listOf(Reply(select, fails = true))))
        for (failing in 1..3) {
            val replies = (prefix() + end).toMutableList()
            replies[failing] = Reply(replies[failing].command, fails = true)
            val partial = read(replies + noCompanion)!!
            assertTrue(partial.realSerialNumber != null || partial.balanceText != null)
        }
        val sparse = read(prefix() + listOf(Reply(record(1), ByteArray(23)), Reply(record(2), invalid),
            Reply(record(3), transaction()), Reply(record(4), status = "6A83"), noCompanion))!!
        assertEquals(listOf(invalid.hexString(), transaction().hexString()), sparse.rawTransactions)
        assertEquals(listOf(2, 3), sparse.applications!!.single().records.map { it.index })
    }

    @Test fun historyIsBoundedAndShortRecordsStopReads() {
        for (length in listOf(0, 1, 22, 24, 46)) {
            val snapshot = read(prefix() + listOf(Reply(record(1), transaction().copyOf(length)), noCompanion))!!
            assertTrue(snapshot.rawTransactions.isEmpty())
            assertNotNull(snapshot.balanceText)
        }
        val records = (1..30).map { transaction(sequence = it) }
        val snapshot = read(prefix() + records.mapIndexed { i, data -> Reply(record(i + 1), data) } + noCompanion)!!
        assertEquals(30, snapshot.rawTransactions.size)
        for (length in 0 until 28) {
            val partial = read(prefix(info = info().copyOf(length)) + listOf(end, noCompanion))!!
            assertNotNull(partial.balanceText)
            if (length < 20) assertNull(partial.realSerialNumber)
            if (length < 24) assertTrue(partial.resultFields.none { it.value == "2024-02-29" })
            assertTrue(partial.resultFields.none { it.value == "2032-06-30" })
        }
    }

    @Test fun lengthCorrectionAndContinuationAreBounded() {
        val retry = read(listOf(
            Reply(select, status = "6C1C"), Reply("00A404000AB0C4C3C5CDA8C7AEB0FC1C"),
            Reply(infoCommand, status = "6C1C"), Reply("00B095001C", info()),
            Reply(balanceCommand, status = "6C00"), Reply("805C000200", uint32(1234)),
            Reply(record(1), status = "6C17"), Reply(record(1), transaction()),
            Reply(record(2), status = "6A83"), noCompanion,
        ))!!
        assertEquals(1, retry.rawTransactions.size)
        assertNotNull(retry.balanceText)
        assertNull(read(listOf(Reply(select, status = "6C1C"), Reply("00A404000AB0C4C3C5CDA8C7AEB0FC1C", status = "6C1C"))))

        val info = info(); val balance = uint32(1234); val history = transaction()
        val chained = read(listOf(
            Reply(select, byteArrayOf(0x6F), "6100"), Reply("00C0000000", byteArrayOf(0)),
            Reply(infoCommand, info.copyOf(12), "6110"), Reply("00C0000010", info.copyOfRange(12, 28)),
            Reply(balanceCommand, balance.copyOf(1), "6101"), Reply("00C0000001", balance.copyOfRange(1, 2), "6102"),
            Reply("00C0000002", balance.copyOfRange(2, 4)),
            Reply(record(1), history.copyOf(7), "6110"), Reply("00C0000010", history.copyOfRange(7, 23)),
            Reply(record(2), status = "6A83"), noCompanion,
        ))!!
        assertEquals("12ABCDEF", chained.identifierValue)
        assertEquals(retry.balanceText, chained.balanceText)
        assertEquals(listOf(history.hexString()), chained.rawTransactions)

        val badContinuation = read(listOf(Reply(select), Reply(infoCommand, info),
            Reply(balanceCommand, balance.copyOf(2), "6102"), Reply("00C0000002", balance.copyOfRange(2, 4), "9001"), end, noCompanion))!!
        assertNull(badContinuation.balanceText)

        val commands = mutableListOf<String>()
        val endless = MacauPassDecoder.read(uid, scannedAt) { apdu ->
            commands.add(apdu.hexString())
            if (commands.size > 64) throw IOException("unbounded")
            byteArrayOf(0x55, 0x61, 0x01)
        }
        assertNull(endless)
        assertEquals(listOf(select) + List(15) { "00C0000001" }, commands)
        assertNull(read(listOf(Reply(select, ByteArray(2049) { 0x55 }))))
        assertNull(read(listOf(Reply(select, status = ""))))
    }

    @Test fun identityRequiresSerialOrUid() {
        val serialOnly = read(prefix() + listOf(end, noCompanion), uid = "")!!
        assertEquals("12ABCDEF", serialOnly.identifierValue)
        assertEquals("12ABCDEF", serialOnly.rawIdentifierValue)
        assertEquals("ISO7816|12ABCDEF", serialOnly.storageIdentifier)
        assertNull(read(prefix(info = byteArrayOf()) + end, uid = ""))
        for (serial in listOf("00000000", "FFFFFFFF")) {
            val placeholder = read(prefix(info = info(serial = serial)) + listOf(end, noCompanion))!!
            assertNull(placeholder.realSerialNumber)
            assertEquals(uid, placeholder.identifierValue)
            assertNotNull(placeholder.balanceText)
        }
    }

    @Test fun coBrandedTUnionIsReadOnSameConnectionWithoutReplacingMacau() {
        val raw = transaction()
        val commands = mutableListOf<String>()
        var selected = ""
        // Semantic co-branded card: each application answers only its own read-only commands.
        val exchange = { apdu: ByteArray ->
            val command = apdu.hexString()
            commands.add(command)
            when {
                command == select -> { selected = "macau"; "9000" }
                command == tUnionSelect -> { selected = "tu"; "9000" }
                command.startsWith("00A4") -> "6A82"
                selected == "macau" && command == infoCommand -> info().hexString() + "9000"
                selected == "macau" && command == balanceCommand -> "000004D29000"
                selected == "macau" && command == record(1) -> raw.hexString() + "9000"
                selected == "tu" && command.startsWith("805C00") -> "000003209000"
                selected == "tu" && command.startsWith("805C01") -> "000000009000"
                selected == "tu" && command.startsWith("00B201C4") -> raw.hexString() + "9000"
                else -> "6A83"
            }.hexToBytes()
        }
        val combined = MacauPassDecoder.read(uid, scannedAt, exchange)!!
        assertEquals(select, commands.first())
        assertEquals(1, commands.count { it == select })
        assertTrue("T-Union is probed only after the Macau reads", commands.indexOf(tUnionSelect) > commands.indexOf(record(2)))
        assertTrue("Read-only instructions only: $commands", commands.all { it.substring(2, 4) in setOf("A4", "B0", "B2", "5C", "C0") })
        val apps = combined.applications!!
        assertEquals(2, apps.size)
        assertEquals(MacauPassDecoder.APPLICATION_AID, combined.selectedAID)
        assertEquals("Macau Pass", combined.cardFamily)
        assertEquals("ISO7816|12ABCDEF", combined.storageIdentifier)
        assertEquals(formatCardMoney(11_340, "MOP", 2), combined.balanceText)
        assertTrue(TransitApplication.primary(apps)!!.isMacauPass)
        assertEquals(formatCardMoney(800, "CNY", 2), apps.single { it.isTUnion }.balanceText)
        assertEquals(listOf(raw.hexString()), apps.single { it.isMacauPass }.records.map { it.hex })
        assertEquals(listOf(raw.hexString()), apps.single { it.isTUnion }.records.filter { it.kind == "transaction" }.map { it.hex })

        // Identical bytes in separate wallets keep their own currency and are not merged.
        val mop = MacauPassDecoder.decodeTransaction(raw)!!.copy(sourceApplicationID = apps.single { it.isMacauPass }.id)
        val cny = mop.copy(amount = -37, currencyCode = "CNY", sourceApplicationID = apps.single { it.isTUnion }.id)
        assertEquals(2, ChineseHistoryMerge.reconcile(listOf(mop, cny)).size)
    }

    @Test fun companionFailureOrMissingMacauBalanceNeverSubstitutesCny() {
        val missing = read(prefix() + listOf(end, Reply(tUnionSelect, fails = true)))!!
        assertEquals(1, missing.applications!!.size)
        assertEquals(formatCardMoney(11_340, "MOP", 2), missing.balanceText)

        // T-Union selects, then every read fails: the Macau purse is still returned alone.
        var tuSelected = false
        val failing = MacauPassDecoder.read(uid, scannedAt) { apdu ->
            val command = apdu.hexString()
            when {
                tuSelected -> throw IOException("tag lost")
                command == select -> "9000".hexToBytes()
                command == tUnionSelect -> { tuSelected = true; "9000".hexToBytes() }
                command == infoCommand -> (info().hexString() + "9000").hexToBytes()
                command == balanceCommand -> "000004D29000".hexToBytes()
                else -> "6A83".hexToBytes()
            }
        }!!
        assertEquals(1, failing.applications!!.size)
        assertEquals(formatCardMoney(11_340, "MOP", 2), failing.balanceText)

        var selected = ""
        val noBalance = MacauPassDecoder.read(uid, scannedAt) { apdu ->
            when (apdu.hexString()) {
                select -> { selected = "macau"; "9000" }
                tUnionSelect -> { selected = "tu"; "9000" }
                infoCommand -> if (selected == "macau") info().hexString() + "9000" else "6A82"
                balanceCommand -> if (selected == "macau") "6982" else "000003209000"
                else -> "6A83"
            }.hexToBytes()
        }!!
        assertEquals(2, noBalance.applications!!.size)
        assertNull("An unavailable MOP balance must not display the CNY purse", noBalance.balanceText)
        assertEquals("Macau Pass", noBalance.cardFamily)

        val full = read(prefix() + listOf(Reply(record(1), transaction()), Reply(record(2), status = "6A83"), noCompanion))!!
        val partial = read(listOf(Reply(select), Reply(infoCommand, info()), Reply(balanceCommand, status = "6982"), end, noCompanion))!!
        val merged = TransitApplication.merge(full.applications!!, partial.applications!!).single()
        assertEquals("A partial rescan keeps the last known Macau balance", full.balanceText, merged.balanceText)
        assertEquals(1, merged.records.size)
    }

    @Test fun unexpectedCompanionErrorsPropagate() {
        val failure = IllegalStateException("unexpected companion selection error")
        val card = Card(prefix() + end)
        val thrown = assertThrows(IllegalStateException::class.java) {
            MacauPassDecoder.read(uid, scannedAt) { apdu ->
                if (apdu.hexString() == tUnionSelect) throw failure
                card.exchange(apdu)
            }
        }
        assertSame(failure, thrown)
        card.assertComplete()
    }
}
