package ad.neko.cardbal.android.nfc

/** Independent public CEPAS wire-field implementation, not a reference-code port.
 * FareBot dc09f6f014ea3675b64bcd38335b4b78d77fa374: card/cepas and transit/ezlink.
 * Only the on-card stored-value purse is read; no SimplyGo backend inference.
 */
internal object CepasProtocol {
    /** The purse read first; the other IDs 0..15 are tried only when it is missing or invalid. */
    const val PURSE_ID = 3
    /** Card commands one read may send before the purse search stops. */
    private const val EXCHANGE_LIMIT = 64
    const val ISSUER_TIME_ZONE = "Asia/Singapore"
    // 1995-01-01 midnight Singapore, not FareBot's conflicting numeric constant.
    // Corroborated by Metrodroid b910c180 EZLinkTransitData + time/Timestamp.
    const val EPOCH_SECONDS = 788_889_600L
    // Saved-record format marker; it stays 3 whichever purse the records came from.
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
    data class ReadResult(val purse: Purse, val purseId: Int, val rawHistory: List<ByteArray>, val historyComplete: Boolean) {
        val family get() = purse.family
        val serial get() = purse.serial
        val balanceMinor get() = purse.balanceMinor
    }

    fun selectFileCommand() = byteArrayOf(0, 0xA4.toByte(), 0, 0, 2, 0x40, 0)
    /** The same SELECT with Le 00, for cards that refuse the case-3 form. */
    fun selectFileWithLeCommand() = byteArrayOf(0, 0xA4.toByte(), 0, 0, 2, 0x40, 0, 0)
    fun purseCommand(purseId: Int = PURSE_ID) = byteArrayOf(0x90.toByte(), 0x32, purseId.toByte(), 0, 0)
    fun historyCommand(offset: Int, count: Int, purseId: Int = PURSE_ID): ByteArray? = if (offset in 0..254 && count in 1..15)
        byteArrayOf(0x90.toByte(), 0x32, purseId.toByte(), 0, 1, offset.toByte(), (count * 16).toByte()) else null

    /** The structural rule a purse fails, or null when [parsePurse] accepts it. */
    fun purseRejection(data: ByteArray): String? = when {
        data.size !in 63..256 -> "length not 63..256"
        data[0] == 0.toByte() || data[0] == 0xFF.toByte() -> "version 00/FF"
        63 + (data[41].toInt() and 255) > data.size -> "63+L exceeds length"
        data.copyOfRange(8, 16).any { (it.toInt() and 255) ushr 4 > 9 || (it.toInt() and 15) > 9 } -> "CAN not BCD"
        else -> null
    }

    /** Complete legacy-layout purses with a BCD CAN only. The CAN names the card
     * only where its prefix is certain; any other valid purse is plain CEPAS. */
    fun parsePurse(data: ByteArray): Purse? {
        if (purseRejection(data) != null) return null
        val serial = data.copyOfRange(8, 16).hex()
        val family = when {
            serial.startsWith("100") -> "EZ-Link"
            serial.startsWith("111") -> "NETS FlashPay"
            serial.startsWith("800") -> "Concession" // CAN 8000–8009
            else -> "CEPAS"
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

    /**
     * Select file 4000 (again with Le if refused; GET PURSE is still tried once
     * without it), then purse 3, then the other purses 0..15 until one passes
     * [parsePurse]. A lost card or an unsupported command ends the search.
     * [log] gets stages, status words and lengths only, never response bytes.
     */
    fun read(log: (String) -> Unit = {}, exchange: (ByteArray) -> ByteArray): ReadResult? {
        var sent = 0
        val counted = { command: ByteArray -> sent++; exchange(command) }
        fun attempt(stage: String, command: ByteArray, maximum: Int): Reply =
            request(command, maximum, counted).also { if (it.data == null) log("$stage: ${it.summary()}") }

        val selected = attempt("select", selectFileCommand(), 256).data != null ||
            attempt("select-le", selectFileWithLeCommand(), 256).data != null
        if (!selected) log("File 4000 not selected; trying purse $PURSE_ID once")
        val candidates = if (selected) listOf(PURSE_ID) + (0..15).filter { it != PURSE_ID } else listOf(PURSE_ID)
        var found: Pair<Int, Purse>? = null
        var stop: String? = null
        for (id in candidates) {
            if (sent >= EXCHANGE_LIMIT) { stop = "command limit reached"; break }
            val reply = attempt("purse $id", purseCommand(id), 256)
            val payload = reply.data
            if (payload == null) {
                stop = reply.stopReason() ?: continue
                break
            }
            val rejection = purseRejection(payload)
            if (rejection != null) {
                log("parse purse $id: $rejection, ${payload.size} bytes, L ${payload.lengthByte()}")
                continue
            }
            found = id to parsePurse(payload)!!
            break
        }
        val (purseId, purse) = found ?: run {
            log("Unsupported: no valid purse" + (stop?.let { " ($it)" } ?: " in ${candidates.size} tried"))
            return null
        }
        if (purseId != PURSE_ID) log("Warning: purse $PURSE_ID unavailable, using purse $purseId")
        if (!selected) log("Warning: purse read without selecting file 4000")
        val records = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < purse.historyCount) {
            val requestedCount = minOf(15, purse.historyCount - offset)
            val command = historyCommand(offset, requestedCount, purseId) ?: break
            val page = attempt("history $offset", command, requestedCount * 16).data ?: break
            if (page.isEmpty() || page.size % 16 != 0) {
                log("history $offset: ${page.size} bytes, not whole records")
                break
            }
            val count = page.size / 16
            repeat(count) { index -> encodeHistory(page.copyOfRange(index * 16, index * 16 + 16))?.let(records::add) }
            offset += count
        }
        if (offset != purse.historyCount) log("Warning: history incomplete, $offset of ${purse.historyCount} records")
        return ReadResult(purse, purseId, records, offset == purse.historyCount)
    }

    /** Payload on exact 9000, otherwise the last status word, length and any transport error. */
    private class Reply(val data: ByteArray?, val status: Int = -1, val length: Int = 0, val error: String? = null) {
        fun summary() = when {
            error != null -> "no reply ($error)"
            status < 0 -> "short reply, $length bytes"
            else -> "status %04X, %d bytes".format(status, length)
        }
        /** A lost card, or CLA/INS not supported: no other purse can answer either. */
        fun stopReason() = when {
            error != null -> "card connection lost: $error"
            status == 0x6D00 || status == 0x6E00 -> "command not supported"
            else -> null
        }
    }

    private fun ByteArray.lengthByte() = if (size > 41) "%02X".format(this[41].toInt() and 255) else "-"

    /** Bounded purse/log reads and GET RESPONSE. */
    private fun request(original: ByteArray, maximum: Int, exchange: (ByteArray) -> ByteArray): Reply {
        var command = original.copyOf()
        var collected = byteArrayOf()
        var correctedLength = false
        var status = -1
        repeat(16) {
            val response = try {
                exchange(command.copyOf())
            } catch (error: Exception) {
                return Reply(null, status, collected.size, error.javaClass.simpleName.ifEmpty { "Exception" })
            }
            if (response.size < 2) return Reply(null, -1, response.size)
            val sw1 = response[response.size - 2].toInt() and 255
            val sw2 = response.last().toInt() and 255
            status = (sw1 shl 8) or sw2
            val payload = response.copyOfRange(0, response.size - 2)
            if (sw1 == 0x6C) {
                // The case-3 SELECT has no Le; its last byte belongs to the file ID.
                val hasLe = command.size == 5 || (command.size > 5 && command.size == (command[4].toInt() and 255) + 6)
                if (payload.isNotEmpty() || correctedLength || !hasLe) return Reply(null, status, payload.size)
                correctedLength = true
                command[command.lastIndex] = sw2.toByte()
            } else {
                if (collected.size + payload.size > maximum) return Reply(null, status, collected.size + payload.size)
                collected += payload
                if (sw1 == 0x90 && sw2 == 0) return Reply(collected, status, collected.size)
                if (sw1 != 0x61) return Reply(null, status, collected.size)
                command = byteArrayOf(0, 0xC0.toByte(), 0, 0, sw2.toByte())
            }
        }
        return Reply(null, status, collected.size)
    }

    private fun unsigned(data: ByteArray, start: Int, count: Int): Long =
        data.copyOfRange(start, start + count).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 255) }
    private fun signed24(data: ByteArray, start: Int): Long {
        val value = unsigned(data, start, 3)
        return if (value and 0x80_0000 == 0L) value else value - 0x100_0000
    }
    private fun ByteArray.hex() = joinToString("") { "%02X".format(it) }
}
