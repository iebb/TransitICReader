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
