package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.*
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import java.io.ByteArrayOutputStream
import java.time.LocalDateTime
import java.time.ZoneId

/** Independent implementation of public PBOC wire facts. See docs/decoding/china-local.md. */
internal object ChineseLocalProtocol {
    enum class Kind(val aids: List<String>, val family: String, val city: String) {
        Shenzhen(listOf("5041592E535A54"), "Shenzhen Tong", "Shenzhen"),
        Wuhan(listOf("4150312E5748435443"), "Wuhan Tong", "Wuhan"),
        Beijing(listOf("4F43", "50424F43"), "Beijing Yikatong", "Beijing");
        companion object { fun from(family: String) = entries.firstOrNull { it.family.equals(family, true) } }
    }
    data class File(val sfi: Int, val data: ByteArray)
    data class Record(val number: Int, val data: ByteArray)
    data class Result(val kind: Kind, val aid: String, val selection: ByteArray, val balance: ByteArray, val balanceMinor: Long,
        val serial: String?, val issueDate: String?, val expiryDate: String?, val files: List<File>, val records: List<Record>)
    data class History(val date: Instant, val amountMinor: Long?, val type: Int, val terminal: String, val counter: Int)

    fun balanceMinor(bytes: ByteArray): Long? {
        if (bytes.size != 4 || bytes.all { it == 0xFF.toByte() }) return null
        // Bit 31 is a flag; the remaining 31 bits include a sign bit for overdrafts.
        val value = uint(bytes) and 0x7FFFFFFF
        return if (value and 0x40000000 == 0L) value else value - 0x80000000
    }
    fun history(bytes: ByteArray): History? {
        if (bytes.size != 23) return null
        val date = bcdDate(bytes.copyOfRange(16, 23)) ?: return null
        val amount = uint(bytes.copyOfRange(5, 9))
        if (amount > Int.MAX_VALUE) return null
        val type = bytes[9].toInt() and 255
        return History(date, when (type) { 2 -> amount; 6, 9 -> -amount; else -> null },
            type, bytes.copyOfRange(10, 16).hexString(), uint(bytes.copyOfRange(0, 2)).toInt())
    }
    fun read(exchange: (ByteArray) -> ByteArray): Result? {
        fun command(request: ByteArray): ByteArray? {
            var current = request; val output = ByteArrayOutputStream(); var corrected = false
            repeat(16) {
                val response = runCatching { exchange(current) }.getOrNull() ?: return null
                if (response.size < 2) return null
                val sw1 = response[response.size - 2].toInt() and 255; val sw2 = response.last().toInt() and 255
                if (sw1 == 0x6C && !corrected) {
                    current = current.clone().also { it[it.lastIndex] = sw2.toByte() }; corrected = true
                } else {
                    if (!(sw1 == 0x90 && sw2 == 0) && sw1 != 0x61) return null
                    if (output.size() + response.size - 2 > 2048) return null
                    output.write(response, 0, response.size - 2)
                    if (sw1 == 0x90) return output.toByteArray()
                    current = byteArrayOf(0, 0xC0.toByte(), 0, 0, sw2.toByte()); corrected = false
                }
            }
            return null
        }
        fun select(aid: String) = command(Iso7816Protocol.selectCommand(aid))
        for (kind in Kind.entries) for (aid in kind.aids) {
            val selection = select(aid) ?: continue
            var usesPurseDF = false
            var balance = command("805C000204".hexToBytes())
            if (balance == null && kind == Kind.Beijing && command("00A4000002100100".hexToBytes()) != null) {
                usesPurseDF = true
                balance = command("805C000204".hexToBytes())
            }
            balance ?: continue
            val minor = balanceMinor(balance) ?: continue
            fun file(sfi: Int): ByteArray? {
                select(aid)
                command(byteArrayOf(0, 0xB0.toByte(), (0x80 or sfi).toByte(), 0, 0))?.let { return it }
                for (path in listOf(byteArrayOf(0x10, 1, 0, sfi.toByte()), byteArrayOf(0, sfi.toByte()))) {
                    select(aid)
                    if (command(byteArrayOf(0, 0xA4.toByte(), 8, 0, path.size.toByte()) + path + byteArrayOf(0)) != null)
                        command("00B0000000".hexToBytes())?.let { return it }
                }
                if (kind != Kind.Shenzhen && command("00A40000023F0000".hexToBytes()) != null)
                    return command(byteArrayOf(0, 0xB0.toByte(), (0x80 or sfi).toByte(), 0, 0))
                return null
            }
            val infoSfi = when (kind) { Kind.Shenzhen -> 0x15; Kind.Wuhan -> 5; Kind.Beijing -> 4 }
            val files = mutableListOf<File>()
            val info = file(infoSfi)?.also { files.add(File(infoSfi, it)) }
            val serialFile = if (kind == Kind.Wuhan) file(10)?.also { files.add(File(10, it)) } else null
            val metadata = metadata(kind, info, serialFile, selection)
            // Short generic PBOC names require corroborating Beijing metadata.
            if (kind == Kind.Beijing && (metadata.first == null || metadata.second == null || metadata.third == null)) continue
            select(aid)
            if (usesPurseDF) command("00A4000002100100".hexToBytes())
            val records = mutableListOf<Record>(); var recordP2 = 0xC4
            for (number in 1..30) {
                var payload = command(byteArrayOf(0, 0xB2.toByte(), number.toByte(), recordP2.toByte(), 23))
                if (number == 1 && payload == null) {
                    for (path in listOf("10010018", "0018")) {
                        select(aid)
                        val bytes = path.hexToBytes()
                        if (command(byteArrayOf(0, 0xA4.toByte(), 8, 0, bytes.size.toByte()) + bytes + byteArrayOf(0)) != null) {
                            recordP2 = 4
                            payload = command(byteArrayOf(0, 0xB2.toByte(), 1, recordP2.toByte(), 23))
                            if (payload != null) break
                        }
                    }
                }
                val bytes = payload ?: break
                if (bytes.size != 23 || bytes.all { it == 0.toByte() || it == 0xFF.toByte() }) break
                records.add(Record(number, bytes))
            }
            return Result(kind, aid, selection, balance, minor, metadata.first, metadata.second, metadata.third, files, records)
        }
        return null
    }
    private fun metadata(kind: Kind, data: ByteArray?, serialFile: ByteArray?, selection: ByteArray): Triple<String?, String?, String?> {
        val info = data ?: if (kind == Kind.Shenzhen) tlv(0x8C, selection) else null
        fun date(offset: Int): String? {
            val bytes = info?.takeIf { it.size >= offset + 4 }?.copyOfRange(offset, offset + 4) ?: return null
            if (bcdDate(bytes + byteArrayOf(0, 0, 0)) == null) return null
            val text = bytes.hexString()
            return "${text.substring(0, 4)}-${text.substring(4, 6)}-${text.substring(6)}"
        }
        val serial = when (kind) {
            Kind.Shenzhen -> info?.takeIf { it.size >= 20 }?.copyOfRange(16, 20)?.takeIf(::validSerial)?.let {
                val value = uint(it.reversedArray()); val sum = value.toString().sumOf { digit -> digit.digitToInt() }
                "$value(${(10 - sum % 10) % 10})"
            }
            Kind.Wuhan -> serialFile?.takeIf { it.size >= 5 }?.copyOfRange(0, 5)?.takeIf(::validSerial)?.hexString()
            Kind.Beijing -> info?.takeIf { it.size >= 32 }?.copyOfRange(0, 8)?.takeIf(::validSerial)?.hexString()
        }
        val issue = date(if (kind == Kind.Beijing) 24 else 20)
        val expiry = date(when (kind) { Kind.Beijing -> 28; Kind.Wuhan -> 16; else -> 24 })
        return if (issue != null && expiry != null && issue > expiry) Triple(serial, null, null) else Triple(serial, issue, expiry)
    }
    private fun validSerial(bytes: ByteArray) = bytes.any { it != 0.toByte() } && bytes.any { it != 0xFF.toByte() }
    private fun bcdDate(bytes: ByteArray): Instant? {
        if (bytes.size != 7 || bytes.any { (it.toInt() and 15) > 9 || (it.toInt() ushr 4 and 15) > 9 }) return null
        val n = bytes.map { (it.toInt() ushr 4 and 15) * 10 + (it.toInt() and 15) }
        val year = n[0] * 100 + n[1]
        if (year !in 1900..2200) return null
        val local = runCatching { LocalDateTime.of(year, n[2], n[3], n[4], n[5], n[6]) }.getOrNull() ?: return null
        val offset = ZoneId.of("Asia/Shanghai").rules.getValidOffsets(local).singleOrNull() ?: return null
        return Instant.fromEpochSeconds(local.toEpochSecond(offset))
    }
    private fun tlv(wanted: Int, bytes: ByteArray, depth: Int = 0): ByteArray? {
        if (depth >= 8) return null
        var position = 0
        while (position + 2 <= bytes.size) {
            val tag = bytes[position++].toInt() and 255
            if (tag and 31 == 31) do {
                if (position >= bytes.size) return null
            } while (bytes[position++].toInt() and 128 != 0)
            if (position >= bytes.size) return null
            var length = bytes[position++].toInt() and 255
            if (length and 128 != 0) {
                val count = length and 127
                if (count !in 1..2 || position + count > bytes.size) return null
                length = uint(bytes.copyOfRange(position, position + count)).toInt(); position += count
            }
            if (position + length > bytes.size) return null
            val body = bytes.copyOfRange(position, position + length); position += length
            if (tag == wanted) return body
            if (tag and 32 != 0) tlv(wanted, body, depth + 1)?.let { return it }
        }
        return null
    }
    private fun uint(bytes: ByteArray) = bytes.fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 255) }
}

class ChineseLocalDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag) = IsoDep.get(tag) != null
    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val technology = IsoDep.get(tag) ?: return null
        return runCatching {
            technology.use { iso ->
                iso.connect(); iso.timeout = 2500
                read(tag.id.hexString(), scannedAt, iso::transceive)
            }
        }.getOrNull()
    }
    companion object {
        internal fun read(uid: String, scannedAt: Instant, exchange: (ByteArray) -> ByteArray): TransitCardSnapshot? {
            val result = ChineseLocalProtocol.read(exchange) ?: return null
            if (uid.isBlank() && result.serial == null) return null
            val fields = mutableListOf(ResultField("Brand", result.kind.family), ResultField("Issuing City", result.kind.city), ResultField("Currency", "CNY"))
            result.serial?.let { fields.add(ResultField("Card Number", it)) }
            result.issueDate?.let { fields.add(ResultField("Issue Date", it)) }
            result.expiryDate?.let { fields.add(ResultField("Expiry Date", it)) }
            val records = result.records.map { TransitApplicationRecord("transaction", 0x18, it.number, it.data.hexString()) }
            val snapshot = TransitCardSnapshot(
                technology = "ISO7816", cardFamily = result.kind.family, identifierLabel = "UID", identifierValue = uid, rawIdentifierValue = uid,
                selectedAID = result.aid, balanceText = formatCardMoney(result.balanceMinor, "CNY", 2),
                realSerialNumber = result.serial, region = result.kind.city, resultFields = fields,
                rawSections = listOf(RawDataSection("Application", listOf(RawDataField("AID", result.aid),
                    RawDataField("SELECT", result.selection.hexString()), RawDataField("Balance", result.balance.hexString())))) +
                    result.files.map { RawDataSection("SFI %02X".format(it.sfi), listOf(RawDataField("Payload", it.data.hexString()))) },
                rawTransactions = records.map { it.hex }, rawTransitHistory = emptyList(), scannedAt = scannedAt,
            )
            return snapshot.copy(applications = listOf(TransitApplication.from(snapshot, records)))
        }
        fun decodeRecord(bytes: ByteArray): TransitTransaction? {
            val h = ChineseLocalProtocol.history(bytes) ?: return null
            val local = java.time.Instant.ofEpochSecond(h.date.epochSeconds).atZone(ZoneId.of("Asia/Shanghai"))
            return TransitTransaction(date = h.date, time = local.toLocalTime().format(java.time.format.DateTimeFormatter.ofPattern("HH:mm:ss")),
                amount = h.amountMinor ?: 0, terminalID = h.terminal, recordNumber = h.counter,
                type = if (h.type == 2) "Top-up" else if (h.amountMinor != null) "Payment" else "Transaction 0x%02X".format(h.type),
                category = if (h.type == 2) TransactionCategory.topUp else if (h.amountMinor != null) TransactionCategory.payment else TransactionCategory.unknown,
                rawData = bytes.hexString(), currencyCode = "CNY", fractionDigits = 2, issuerTimeZone = "Asia/Shanghai",
                amountKnown = h.amountMinor != null, amountIsSigned = true)
        }
    }
}
