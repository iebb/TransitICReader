package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransitTransaction
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

internal object JapaneseCardFormats {
    fun number(block: ByteArray?, offset: Int = 0): String? = block?.takeIf { it.size == 16 }
        ?.copyOfRange(offset, offset + 8)?.takeIf { bytes -> bytes.any { it != 0.toByte() } && bytes.all { (it.toInt() and 15) <= 9 && ((it.toInt() and 255) shr 4) <= 9 } }?.hexString()

    fun uint(data: ByteArray, start: Int, count: Int, little: Boolean = false): Long {
        if (start < 0 || count !in 1..4 || start + count > data.size) return 0
        val bytes = data.copyOfRange(start, start + count)
        return (if (little) bytes.reversedArray() else bytes).fold(0L) { a, b -> (a shl 8) or (b.toLong() and 255) }
    }

    fun date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0): Instant? = runCatching {
        Instant.fromEpochMilliseconds(LocalDateTime.of(year, month, day, hour, minute, second).atZone(ZoneId.of("Asia/Tokyo")).toInstant().toEpochMilli())
    }.getOrNull()

    fun packedDate(value: Int): String? = runCatching { LocalDate.of(2000 + (value shr 9), (value shr 5) and 15, value and 31).toString() }.getOrNull()

    /** nanaco service 560B block 1 holds two big-endian 24-bit point buckets at bytes 0-2 and 5-7. */
    fun nanacoPoints(block: ByteArray?): Long? = block?.takeIf { it.size == 16 }?.let { uint(it, 0, 3) + uint(it, 5, 3) }

    /** WAON service 684B block 0 holds points as a big-endian 24-bit value. */
    fun waonPoints(block: ByteArray?): Long? = block?.takeIf { it.size >= 3 }?.let { uint(it, 0, 3) }

    fun waonTypeName(type: Int): String = when (type) {
        0x04 -> "Payment"
        0x0C, 0x10 -> "Top-up"
        0x08 -> "Return"
        0x18 -> "Point Download"
        0x28 -> "Refund"
        0x1C, 0x20, 0x30 -> "Auto Charge"
        0x3C -> "Move to New Card"
        0x7C -> "Point Exchange"
        else -> "Transaction 0x%02X".format(type)
    }

    /** Payments use the usage field and top-ups the charge field; other operations keep the larger of the two. */
    fun waonType(type: Int, usage: Long, charge: Long): Triple<String, TransactionCategory, Long> = when (type) {
        0x04 -> Triple(waonTypeName(type), TransactionCategory.payment, usage)
        0x0C, 0x10 -> Triple(waonTypeName(type), TransactionCategory.topUp, charge)
        else -> Triple(waonTypeName(type), TransactionCategory.unknown, maxOf(usage, charge))
    }

    fun edy(data: ByteArray, raw: String): TransitTransaction? {
        if (data.size != 16) return null
        val clock = uint(data, 4, 4)
        val seconds = (clock and 0x1ffff).toInt()
        if (seconds >= 86400) return null
        val localDay = LocalDate.of(2000, 1, 1).plusDays(clock shr 17)
        val timestamp = date(localDay.year, localDay.monthValue, localDay.dayOfMonth, seconds / 3600, seconds / 60 % 60, seconds % 60) ?: return null
        val (label, category) = when (data[0].toInt() and 255) {
            0x02 -> "Top-up" to TransactionCategory.topUp
            0x04 -> "Edy Gift" to TransactionCategory.topUp
            0x20 -> "Payment" to TransactionCategory.payment
            else -> "Edy transaction" to TransactionCategory.unknown
        }
        return TransitTransaction(date = timestamp, time = "%02d:%02d:%02d".format(seconds / 3600, seconds / 60 % 60, seconds % 60),
            amount = uint(data, 8, 4), balanceAfter = uint(data, 12, 4), recordNumber = uint(data, 2, 2).toInt(),
            type = label, category = category, rawData = raw, currencyCode = "JPY", issuerTimeZone = "Asia/Tokyo")
    }

    fun nanaco(data: ByteArray, raw: String): TransitTransaction? {
        if (data.size != 16) return null
        val clock = uint(data, 9, 4)
        val timestamp = date(2000 + ((clock shr 21) and 2047).toInt(), ((clock shr 17) and 15).toInt(), ((clock shr 12) and 31).toInt(), ((clock shr 6) and 63).toInt(), (clock and 63).toInt())
        val (label, category) = when (data[0].toInt() and 255) {
            0x47 -> "Payment" to TransactionCategory.payment
            0x5c, 0x6f, 0x70 -> "Top-up" to TransactionCategory.topUp
            0x83 -> "Points exchange" to TransactionCategory.topUp
            0x35 -> "Transfer" to TransactionCategory.adjustment
            else -> "nanaco transaction" to TransactionCategory.unknown
        }
        return TransitTransaction(date = timestamp, amount = uint(data, 1, 4), balanceAfter = uint(data, 5, 4),
            recordNumber = uint(data, 13, 2).toInt(), type = label, category = category, rawData = raw, currencyCode = "JPY", issuerTimeZone = "Asia/Tokyo")
    }

    fun ryuto(data: ByteArray, raw: String): TransitTransaction? {
        if (data.size != 16 || (data[9].toInt() and 255) !in setOf(0x52, 0x55)) return null
        val b = data.map { it.toInt() and 255 }
        val year = 2000 + (b[0] shr 1); val month = ((b[0] and 1) shl 3) or (b[1] shr 5); val day = b[1] and 31
        val board = date(year, month, day, (b[2] shr 2) and 31, ((b[2] and 3) shl 4) or (b[3] shr 4)) ?: return null
        val timestamp = date(year, month, day, ((b[3] and 7) shl 2) or (b[4] shr 6), b[4] and 63) ?: return null
        val topUp = b[9] == 0x55
        val entry = data.copyOfRange(5, 7).hexString(); val exit = data.copyOfRange(7, 9).hexString()
        return TransitTransaction(date = timestamp, amount = uint(data, 10, 2), balanceAfter = uint(data, 14, 2),
            type = if (topUp) "Top-up" else "Bus", category = if (topUp) TransactionCategory.topUp else TransactionCategory.bus,
            entryStation = if (topUp) null else "Bus stop $entry", exitStation = if (topUp) null else "Bus stop $exit",
            location = if (topUp) null else "Bus stop $entry → $exit", rawData = raw, currencyCode = "JPY", issuerTimeZone = "Asia/Tokyo")
    }

    fun okica(data: ByteArray, raw: String, previous: ByteArray?): TransitTransaction? {
        if (data.size != 16) return null
        val use = uint(data, 0, 4)
        val (type, category) = when (use) {
            0x16010002L -> "Yui Rail" to TransactionCategory.train
            0x08020000L, 0x08480000L, 0x08480400L, 0x051f0000L, 0x1f1f0000L -> "Top-up" to TransactionCategory.topUp
            0x050f000fL -> "Bus" to TransactionCategory.bus
            0x08070000L -> "New card issuance" to TransactionCategory.adjustment
            else -> "OKICA transaction %08X".format(use) to TransactionCategory.unknown
        }
        val balance = uint(data, 10, 2, true)
        val day = uint(data, 4, 2).toInt()
        fun station(offset: Int): Pair<String, String?>? {
            val code = uint(data, offset, 2).toInt()
            if (code == 0) return null
            if ((code and 0xff00) == 0xdc00) return "Station %04X".format(code) to "%05X".format(0x30000 or code)
            return (mapOf(0x0b01 to "Naha Bus", 0x0b02 to "Ryukyu Bus Kotsu", 0x0b03 to "Okinawa Bus", 0x0b04 to "Toyo Bus")[code] ?: "Location %04X".format(code)) to null
        }
        val entry = station(6); val exit = station(8)
        return TransitTransaction(date = date(2000 + (day shr 9), (day shr 5) and 15, day and 31),
            amount = previous?.takeIf { it.size == 16 }?.let { kotlin.math.abs(balance - uint(it, 10, 2, true)) } ?: 0,
            balanceAfter = balance, recordNumber = uint(data, 13, 2).toInt(), type = type, category = category,
            entryStation = entry?.first, exitStation = exit?.first, entryStationCode = entry?.second, exitStationCode = exit?.second,
            rawData = raw, currencyCode = "JPY", issuerTimeZone = "Asia/Tokyo")
    }
}

/**
 * Hanica (Hankyu Bus / Hanshin Bus): one system 84A1 with the bus-platform log shared by
 * Ryuto, ICa and Passca (service 898F, newest first). Dates and stops share one packing;
 * the balance position and unit differ across that family and Hanica's is undocumented,
 * so a balance is used only when exactly one known layout makes the log self-consistent.
 * Mirrors ios/CardBal/NFC/Profiles/HanicaCardFormat.swift.
 */
internal object HanicaCardFormat {
    const val SYSTEM_CODE = "84A1"
    const val SERVICE = "8F89"
    const val HISTORY_READ_LIMIT = 20
    /** The largest stored value a Japanese bus IC card accepts. */
    const val MAXIMUM_BALANCE_YEN = 30_000
    /** No fare or top-up is smaller; separates whole-yen from 10-yen units on the same bytes. */
    const val MINIMUM_AMOUNT_YEN = 50

    data class Layout(val name: String, val balanceOffset: Int, val amountOffset: Int, val unitYen: Int) {
        fun balance(block: ByteArray): Int = JapaneseCardFormats.uint(block, balanceOffset, 2).toInt() * unitYen
        fun amount(block: ByteArray): Int = JapaneseCardFormats.uint(block, amountOffset, 2).toInt() * unitYen
        val summary: String get() = "$name: balance bytes $balanceOffset-${balanceOffset + 1}, amount bytes " +
            "$amountOffset-${amountOffset + 1}, big-endian, ${if (unitYen == 1) "yen" else "units of $unitYen yen"}"
    }

    val ryutoStyle = Layout("Ryuto-style", 14, 10, 1)
    val passcaStyle = Layout("Passca-style", 14, 10, 10)
    val icaStyle = Layout("ICa-style", 13, 10, 1)
    val layouts = listOf(ryutoStyle, passcaStyle, icaStyle)

    data class Record(val boardingDate: Instant?, val date: Instant?, val boardingStop: String, val alightingStop: String, val typeCode: Int) {
        val hasValidDates: Boolean get() = boardingDate != null && date != null
        val isTopUpType: Boolean get() = typeCode == 0x55
        val isRideType: Boolean get() = typeCode == 0x52
    }

    data class Value(val amount: Int, val balance: Int, val isTopUp: Boolean)

    fun isLogBlock(block: ByteArray): Boolean = block.size == 16 && block.any { it != 0.toByte() }

    fun decode(data: ByteArray): Record? {
        if (!isLogBlock(data)) return null
        val b = data.map { it.toInt() and 255 }
        val year = 2000 + (b[0] shr 1); val month = ((b[0] and 1) shl 3) or (b[1] shr 5); val day = b[1] and 31
        fun at(hour: Int, minute: Int) = if (hour in 0..23 && minute in 0..59) JapaneseCardFormats.date(year, month, day, hour, minute) else null
        return Record(at((b[2] shr 2) and 31, ((b[2] and 3) shl 4) or (b[3] shr 4)), at(((b[3] and 7) shl 2) or (b[4] shr 6), b[4] and 63),
            "%02X%02X".format(b[5], b[6]), "%02X%02X".format(b[7], b[8]), b[9])
    }

    /** The only layout the log (newest first) proves, or null when none or several fit. */
    fun detectLayout(blocks: List<ByteArray>): Layout? = layouts.filter { accepts(it, blocks) }.singleOrNull()

    /**
     * At least two consecutive pairs move the balance by exactly the newer amount, no dated
     * pair contradicts it, every balance is within the stored-value limit and every proven
     * amount is a plausible fare or top-up.
     */
    fun accepts(layout: Layout, blocks: List<ByteArray>): Boolean {
        val log = blocks.filter { isLogBlock(it) }
        if (log.size < 3 || log.any { layout.balance(it) > MAXIMUM_BALANCE_YEN }) return false
        var consistent = 0
        for (index in 0 until log.size - 1) {
            val newer = log[index]; val older = log[index + 1]
            if (direction(layout, newer, older) != null) {
                if (layout.amount(newer) < MINIMUM_AMOUNT_YEN) return false
                consistent++
                continue
            }
            // A zero-amount record that leaves the balance unchanged neither proves nor refutes.
            if (layout.amount(newer) == 0 && layout.balance(newer) == layout.balance(older)) continue
            if (decode(newer)?.hasValidDates == true && decode(older)?.hasValidDates == true) return false
        }
        return consistent >= 2
    }

    /** True for a top-up, false for a fare, null when the pair does not fit the layout. */
    fun direction(layout: Layout, newer: ByteArray, older: ByteArray): Boolean? {
        val amount = layout.amount(newer)
        if (amount <= 0) return null
        val balance = layout.balance(newer); val previous = layout.balance(older)
        return when (balance) {
            previous - amount -> false
            previous + amount -> true
            else -> null
        }
    }

    /** Amount and balance of `blocks[index]` under `layout`; null without a confirmed layout. */
    fun value(index: Int, blocks: List<ByteArray>, layout: Layout?): Value? {
        val block = blocks.getOrNull(index) ?: return null
        if (layout == null || !isLogBlock(block)) return null
        val older = blocks.getOrNull(index + 1)?.takeIf { isLogBlock(it) }
        val topUp = older?.let { direction(layout, block, it) } ?: ((block[9].toInt() and 255) == 0x55)
        return Value(layout.amount(block), layout.balance(block), topUp)
    }

    /** The current balance in yen, from the newest record, when a layout is confirmed. */
    fun confirmedBalance(blocks: List<ByteArray>): Pair<Layout, Int>? {
        val layout = detectLayout(blocks) ?: return null
        val newest = blocks.firstOrNull()?.takeIf { isLogBlock(it) } ?: return null
        return layout to layout.balance(newest)
    }

    /** Dates and stops always; fare and balance only when the log confirms one layout. */
    fun transaction(data: ByteArray, raw: String, context: List<ByteArray>, index: Int): TransitTransaction? {
        val record = decode(data) ?: return null
        val blocks = if (context.getOrNull(index)?.contentEquals(data) == true) context else listOf(data)
        val value = value(if (blocks.size == 1) 0 else index, blocks, detectLayout(blocks))
        val topUp = value?.isTopUp ?: record.isTopUpType
        val ride = value?.let { !it.isTopUp } ?: record.isRideType
        val stops = !topUp && (record.boardingStop != "0000" || record.alightingStop != "0000")
        return TransitTransaction(date = record.date, amount = value?.amount?.toLong() ?: 0, balanceAfter = value?.balance?.toLong(),
            type = if (topUp) "Top-up" else if (ride) "Bus" else "Transaction",
            category = if (topUp) TransactionCategory.topUp else if (ride) TransactionCategory.bus else TransactionCategory.unknown,
            entryStation = if (stops) "Bus stop ${record.boardingStop}" else null, exitStation = if (stops) "Bus stop ${record.alightingStop}" else null,
            location = if (stops) "Bus stop ${record.boardingStop} → ${record.alightingStop}" else null,
            rawData = raw, currencyCode = "JPY", issuerTimeZone = "Asia/Tokyo", amountKnown = value != null)
    }
}
