package ad.neko.cardbal.android.nfc

import java.time.LocalDateTime
import java.time.ZoneId

/** Independent implementation of published wire-format facts, not GPL code.
 * https://github.com/metrodroid/metrodroid/wiki/Snapper
 * Pinned reference b910c1806fd86aa545223baf1d21fc5afe68eee2 confirms trip length52.
 */
internal object SnapperPlusProtocol {
    const val APPLICATION_AID = "D4100000030001"
    private val envelope = byteArrayOf(0x53, 0x50, 0x2B, 0x01)

    data class History(
        val transactionBytes: ByteArray,
        val tripBytes: ByteArray?,
        val recordNumber: Int,
        val transactionType: Int,
        val counter: Long,
        val amountMinor: Long,
        val balanceMinor: Long,
        val operatorID: String?,
        val timestampMillis: Long?,
        val journeyID: Int?,
        val sequence: Int?,
        val isTapOn: Boolean?,
    )

    fun matches(aid: String, issuerID: Int?, transactionRecords: List<ByteArray>): Boolean =
        aid.equals(APPLICATION_AID, ignoreCase = true) && issuerID == 2 &&
            transactionRecords.isNotEmpty() && transactionRecords.all(::isTransactionRecord)

    fun isTransactionRecord(data: ByteArray): Boolean =
        data.size == 46 && data[0].toInt() in 1..2 && data[1] == 0x2C.toByte() &&
            data.sliceArray(26 until 46).all { it == 0xFF.toByte() }

    fun balanceMinor(response: ByteArray): Long? =
        if (response.size == 6 && response.isSuccess) signed32(response, 0) else null

    fun encodeHistory(transaction: ByteArray, trip: ByteArray?, recordNumber: Int): ByteArray? {
        if (recordNumber !in 1..255 || !isTransactionRecord(transaction)) return null
        val validTrip = trip?.takeIf(::isTripRecord)
        return envelope + byteArrayOf(recordNumber.toByte(), if (validTrip == null) 0 else 52) +
            transaction + (validTrip ?: byteArrayOf())
    }

    fun decodeHistory(data: ByteArray): History? {
        if (data.size < 6 || !data.copyOfRange(0, 4).contentEquals(envelope) ||
            data[4] == 0.toByte() || data[5].toInt() !in listOf(0, 52) || data.size != 52 + data[5].toInt()) return null
        val tx = data.copyOfRange(6, 52)
        if (!isTransactionRecord(tx)) return null
        val trip = if (data[5] == 52.toByte()) data.copyOfRange(52, 104) else null
        if (trip != null && !isTripRecord(trip)) return null
        val millis = trip?.let(::tripMillis)
        val agency = tx.copyOfRange(14, 19).joinToString("") { "%02X".format(it) }.take(9)
            .takeIf { value -> value.all { it in '0'..'9' } }
        val cost = signed32(tx, 10)
        return History(
            transactionBytes = tx, tripBytes = trip,
            recordNumber = data[4].toInt() and 0xFF, transactionType = tx[0].toInt(),
            counter = unsigned32(tx, 6), amountMinor = if (tx[0] == 2.toByte()) cost else -cost,
            balanceMinor = signed32(tx, 2), operatorID = agency, timestampMillis = millis,
            journeyID = if (millis != null) trip!![5].toInt() and 0xFF else null,
            sequence = if (millis != null) trip!![4].toInt() and 0xFF else null,
            isTapOn = if (millis != null) (trip!![51].toInt() and 0x10) != 0 else null,
        )
    }

    /** Incoming first; ring slots are not identity. Unknown formats survive. */
    fun mergeHistory(records: List<String>): List<String> {
        val result = mutableListOf<String>()
        val known = mutableMapOf<List<Byte>, Pair<Int, Int>>()
        val unknown = mutableSetOf<String>()
        for (raw in records) {
            val bytes = if (raw.length % 2 == 0 && raw.all { it in '0'..'9' || it in 'A'..'F' || it in 'a'..'f' }) {
                raw.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            } else null
            val history = bytes?.let(::decodeHistory)
            if (history == null) {
                if (unknown.add(raw)) result.add(raw)
                continue
            }
            val key = history.transactionBytes.toList()
            val quality = if (history.timestampMillis != null) 2 else if (history.tripBytes != null) 1 else 0
            val previous = known[key]
            if (previous == null) {
                known[key] = result.size to quality
                result.add(raw)
            } else if (quality > previous.second) {
                result[previous.first] = raw
                known[key] = previous.first to quality
            }
        }
        return result
    }

    data class ReadResult(
        val balanceMinor: Long,
        val history: List<ByteArray>,
        val transactions: Map<Int, ByteArray>,
        val trips: Map<Int, ByteArray>,
    )

    /** All requests are SELECT-independent, read-only balance/record commands. */
    fun read(aid: String, selectionResponse: ByteArray, balanceResponse: ByteArray,
             exchange: (ByteArray) -> ByteArray): ReadResult? {
        if (!selectionResponse.isSuccess || !aid.equals(APPLICATION_AID, ignoreCase = true)) return null
        val issuer = purseIssuer(selectionResponse.dropLast(2).toByteArray())
        if (issuer != 2) return null
        val balance = balanceMinor(balanceResponse) ?: return null
        val transactions = linkedMapOf<Int, ByteArray>()
        for (number in 1..20) {
            val record = readRecord(4, number, exchange) ?: break
            if (record.isEmpty() || record.all { it == 0.toByte() || it == 0xFF.toByte() }) break
            transactions[number] = record
        }
        if (!matches(aid, issuer, transactions.values.toList())) return null
        val trips = linkedMapOf<Int, ByteArray>()
        val history = transactions.mapNotNull { (number, transaction) ->
            val trip = readRecord(3, number, exchange)
            if (trip != null) trips[number] = trip
            encodeHistory(transaction, trip, number)
        }
        return ReadResult(balance, history, transactions, trips)
    }

    private fun readRecord(sfi: Int, number: Int, exchange: (ByteArray) -> ByteArray): ByteArray? {
        val command = byteArrayOf(0, 0xB2.toByte(), number.toByte(), ((sfi shl 3) or 4).toByte(), 0)
        var response = runCatching { exchange(command) }.getOrNull() ?: return null
        if (response.size == 2 && response[0] == 0x6C.toByte()) {
            command[4] = response[1]
            response = runCatching { exchange(command) }.getOrNull() ?: return null
        }
        return if (response.isSuccess) response.dropLast(2).toByteArray() else null
    }

    /** FCI purse tag B0 uses issuer byte3; require a complete, unambiguous TLV. */
    fun purseIssuer(fci: ByteArray): Int? = purseData(fci)?.get(3)?.toInt()?.and(0xFF)

    /** Same eight-byte purse CSN and grouping used by the iPhone reader. */
    fun normalizedSerial(serial: String?): String? {
        val hex = serial?.filterNot(Char::isWhitespace)?.uppercase() ?: return null
        if (hex.length != 16 || !hex.all { it in '0'..'9' || it in 'A'..'F' } ||
            hex.all { it == '0' } || hex.all { it == 'F' }) return null
        return hex.chunked(4).joinToString(" ")
    }

    fun purseSerial(fci: ByteArray): String? = normalizedSerial(purseData(fci)?.copyOfRange(4, 12)
        ?.joinToString("") { "%02X".format(it) })

    private fun purseData(fci: ByteArray): ByteArray? {
        val purses = mutableListOf<ByteArray>()
        fun scan(start: Int, end: Int, depth: Int): Boolean {
            if (depth > 8) return false
            var offset = start
            while (offset < end) {
                val tag = fci[offset++].toInt() and 0xFF
                if ((tag and 31) == 31) {
                    var count = 1
                    do {
                        if (offset >= end || ++count > 4) return false
                        val next = fci[offset++].toInt() and 0xFF
                    } while ((next and 0x80) != 0)
                }
                if (offset >= end) return false
                val initial = fci[offset++].toInt() and 0xFF
                var length = initial
                if (initial >= 128) {
                    val count = initial and 127
                    if (count !in 1..3 || count > end - offset) return false
                    length = 0
                    repeat(count) { length = (length shl 8) or (fci[offset++].toInt() and 0xFF) }
                }
                if (length > end - offset) return false
                val next = offset + length
                if (tag == 0xB0) {
                    if (length < 47) return false
                    purses.add(fci.copyOfRange(offset, next))
                } else if ((tag and 0x20) != 0 && !scan(offset, next, depth + 1)) return false
                offset = next
            }
            return true
        }
        return if (scan(0, fci.size, 0)) purses.singleOrNull() else null
    }

    private fun isTripRecord(data: ByteArray): Boolean =
        data.size == 52 && data[0] == 1.toByte() && data[1] == 0x32.toByte()

    private fun tripMillis(data: ByteArray): Long? {
        if (!isTripRecord(data)) return null
        val raw = data.copyOfRange(13, 20).map { it.toInt() and 0xFF }
        if (raw.any { (it shr 4) > 9 || (it and 15) > 9 }) return null
        val v = raw.map { (it shr 4) * 10 + (it and 15) }
        val year = v[0] * 100 + v[1]
        if (year !in 2000..2199) return null
        return runCatching {
            val local = LocalDateTime.of(year, v[2], v[3], v[4], v[5], v[6])
            val zone = ZoneId.of("Pacific/Auckland")
            val offsets = zone.rules.getValidOffsets(local)
            if (offsets.size != 1) null else local.toInstant(offsets.single()).toEpochMilli()
        }.getOrNull()
    }

    private fun unsigned32(data: ByteArray, at: Int): Long =
        data.copyOfRange(at, at + 4).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 0xFF) }

    private fun signed32(data: ByteArray, at: Int): Long = unsigned32(data, at).toInt().toLong()
}
