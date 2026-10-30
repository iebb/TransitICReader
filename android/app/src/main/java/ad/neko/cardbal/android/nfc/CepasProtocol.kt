package ad.neko.cardbal.android.nfc

/** Independent public CEPAS wire-field implementation, not a reference-code port.
 * FareBot dc09f6f014ea3675b64bcd38335b4b78d77fa374: card/cepas and transit/ezlink.
 * Only the on-card stored-value purse is read; no SimplyGo backend inference.
 */
internal object CepasProtocol {
    const val PURSE_ID = 3
    const val ISSUER_TIME_ZONE = "Asia/Singapore"
    // 1995-01-01 midnight Singapore, not FareBot's conflicting numeric constant.
    // Corroborated by Metrodroid b910c180 EZLinkTransitData + time/Timestamp.
    const val EPOCH_SECONDS = 788_889_600L
    private val envelope = byteArrayOf(0x43, 0x45, 0x50, 1, PURSE_ID.toByte())

    data class Purse(
        val family: String, val serial: String, val chipSerial: String,
        val version: Int, val status: Int, val balanceMinor: Long,
        val historyCount: Int, val creationEpochSeconds: Long, val expiryEpochSeconds: Long,
        val raw: ByteArray,
    )
    enum class Kind { Train, Bus, TopUp, Refund, Creation, Purchase, Service, Unknown }
    data class History(
        val rawType: Int, val kind: Kind, val type: String, val amountMinor: Long,
        val hasMonetaryAmount: Boolean, val epochSeconds: Long?, val userData: String?, val record: ByteArray,
    )
    data class ReadResult(val purse: Purse, val rawHistory: List<ByteArray>, val historyComplete: Boolean) {
        val family get() = purse.family
        val serial get() = purse.serial
        val balanceMinor get() = purse.balanceMinor
    }

    fun purseCommand() = byteArrayOf(0x90.toByte(), 0x32, PURSE_ID.toByte(), 0, 0)
    fun historyCommand(offset: Int): ByteArray? = if (offset in 0..254)
        byteArrayOf(0x90.toByte(), 0x32, PURSE_ID.toByte(), 0, 1, offset.toByte(), 0) else null

    fun parsePurse(data: ByteArray): Purse? {
        if (data.size !in 63..256 || data[0] == 0.toByte() || data[0] == 0xFF.toByte() ||
            63 + (data[41].toInt() and 255) > data.size) return null
        val can = data.copyOfRange(8, 16)
        if (can.any { (it.toInt() and 255) ushr 4 > 9 || (it.toInt() and 15) > 9 }) return null
        val serial = can.hex()
        val family = when {
            serial.startsWith("100") -> "EZ-Link"
            serial.startsWith("111") -> "NETS FlashPay"
            else -> return null
        }
        return Purse(family, serial, data.copyOfRange(16, 24).hex(), data[0].toInt() and 255,
            data[1].toInt() and 255, signed24(data, 2), data[40].toInt() and 255,
            EPOCH_SECONDS + unsigned(data, 26, 2) * 86400, EPOCH_SECONDS + unsigned(data, 24, 2) * 86400,
            data.copyOf())
    }

    fun encodeHistory(record: ByteArray): ByteArray? =
        if (record.size == 16 && record.any { it != 0.toByte() } && record.any { it != 0xFF.toByte() }) envelope + record else null

    fun decodeHistory(data: ByteArray): History? {
        if (data.size != 21 || !data.copyOfRange(0, 5).contentEquals(envelope)) return null
        val record = data.copyOfRange(5, 21)
        if (encodeHistory(record) == null) return null
        val rawType = record[0].toInt() and 255
        val (kind, type) = when (rawType) {
            0x30 -> Kind.Train to "MRT"
            0x31 -> Kind.Bus to "Bus"
            0x03, 0x75 -> Kind.TopUp to "Top-up"
            0x76 -> Kind.Refund to "Bus refund"
            0x05, 0xF0 -> Kind.Creation to "Card creation"
            0x01 -> Kind.Purchase to "Retail purchase"
            0x04 -> Kind.Service to "Service charge"
            else -> Kind.Unknown to "CEPAS record 0x%02X".format(rawType)
        }
        val seconds = unsigned(record, 4, 4)
        val user = record.copyOfRange(8, 16)
        val printable = user.all { it == 0.toByte() || (it.toInt() and 255) in 0x20..0x7E }
        val text = if (printable) user.takeWhile { it != 0.toByte() }.toByteArray().toString(Charsets.US_ASCII).trim().ifEmpty { null } else null
        return History(rawType, kind, type, signed24(record, 1), kind != Kind.Creation,
            if (seconds == 0L || seconds == 0xFFFFFFFFL) null else EPOCH_SECONDS + seconds, text, record)
    }

    fun read(exchange: (ByteArray) -> ByteArray): ReadResult? {
        val purse = request(purseCommand(), 256, exchange)?.let(::parsePurse) ?: return null
        val records = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < purse.historyCount) {
            val command = historyCommand(offset) ?: break
            val page = request(command, 4096, exchange) ?: break
            if (page.isEmpty() || page.size % 16 != 0) break
            val count = page.size / 16
            if (count > purse.historyCount - offset) break
            repeat(count) { index -> encodeHistory(page.copyOfRange(index * 16, index * 16 + 16))?.let(records::add) }
            offset += count
        }
        return ReadResult(purse, records, offset == purse.historyCount)
    }

    /** No writes: bounded GET PURSE/log, GET RESPONSE and one length correction. */
    private fun request(original: ByteArray, maximum: Int, exchange: (ByteArray) -> ByteArray): ByteArray? {
        var command = original.copyOf()
        var collected = byteArrayOf()
        var correctedLength = false
        repeat(16) {
            val response = runCatching { exchange(command.copyOf()) }.getOrNull() ?: return null
            if (response.size < 2) return null
            val sw1 = response[response.size - 2].toInt() and 255
            val sw2 = response.last().toInt() and 255
            val payload = response.copyOfRange(0, response.size - 2)
            if (sw1 == 0x6C) {
                if (payload.isNotEmpty() || correctedLength) return null
                correctedLength = true
                command[command.lastIndex] = sw2.toByte()
            } else {
                if (collected.size + payload.size > maximum) return null
                collected += payload
                if (sw1 == 0x90 && sw2 == 0) return collected
                if (sw1 != 0x61) return null
                command = byteArrayOf(0, 0xC0.toByte(), 0, 0, sw2.toByte())
            }
        }
        return null
    }

    private fun unsigned(data: ByteArray, start: Int, count: Int): Long =
        data.copyOfRange(start, start + count).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 255) }
    private fun signed24(data: ByteArray, start: Int): Long {
        val value = unsigned(data, start, 3)
        return if (value and 0x80_0000 == 0L) value else value - 0x100_0000
    }
    private fun ByteArray.hex() = joinToString("") { "%02X".format(it) }
}
