// SPDX-License-Identifier: MIT
// Macau Pass format adapted from TU-Reader. Copyright (c) 2026 HaoTian22.
// See docs/decoding/macau-pass.md and docs/licenses/TU-Reader-MIT.txt.
package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.*
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.time.LocalDateTime
import java.time.ZoneId

/** Read-only Macau Pass purse. A co-branded T-Union purse is read on the same connection. */
class MacauPassDecoder : TransitCardDecoder {
    // A co-branded card may initially select its T-Union application.
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val technology = IsoDep.get(tag) ?: return null
        return try {
            technology.use { iso ->
                iso.connect(); iso.timeout = 2500
                read(tag.id.hexString(), scannedAt, iso::transceive)
            }
        } catch (_: IOException) {
            null
        }
    }

    companion object {
        const val APPLICATION_AID = "B0C4C3C5CDA8C7AEB0FC"
        const val FAMILY = "Macau Pass"
        const val ISSUER_TIME_ZONE = "Asia/Macau"
        private const val TUNION_AID = "A000000632010105"
        private const val MAX_COMMANDS = 16
        private const val MAX_RESPONSE_BYTES = 2048

        internal fun read(uid: String, scannedAt: Instant, exchange: (ByteArray) -> ByteArray): TransitCardSnapshot? {
            val selected = runCatching { transmit(Iso7816Protocol.selectCommand(APPLICATION_AID), exchange) }.getOrNull() ?: return null
            val sections = mutableListOf(RawDataSection("Macau Pass Application", listOf(
                RawDataField("AID", APPLICATION_AID), RawDataField("Select Response", selected.hexString()))))
            val failures = mutableListOf<RawDataField>()
            val info = runCatching { transmit("00B0950000".hexToBytes(), exchange) }
                .onFailure { failures.add(RawDataField("Information", describe(it))) }.getOrNull()
            info?.let { sections.add(RawDataSection("Macau Pass Information (SFI 15)", listOf(RawDataField("Payload", it.hexString())))) }
            var balanceMinor: Long? = null
            runCatching { transmit("805C000204".hexToBytes(), exchange) }.onSuccess { payload ->
                sections.add(RawDataSection("Macau Pass Balance", listOf(RawDataField("Payload", payload.hexString()),
                    RawDataField("Unit", "0.1 MOP"), RawDataField("Reserve", "MOP 10.00"))))
                // TU-Reader's high-bit heuristic is documented for Shenzhen only.
                // Preserve such Macau values as raw data until their meaning is known.
                if (payload.size == 4 && (payload[0].toInt() and 0x80) == 0) balanceMinor = uint(payload, 0, 4) * 10 - 1000
                else failures.add(RawDataField("Balance", "Unrecognized balance layout"))
            }.onFailure { failures.add(RawDataField("Balance", describe(it))) }

            val records = mutableListOf<TransitApplicationRecord>()
            for (index in 1..30) {
                val payload = try {
                    transmit(byteArrayOf(0, 0xB2.toByte(), index.toByte(), 0xC4.toByte(), 23), exchange)
                } catch (error: Exception) {
                    // 6A83 ends the cyclic history file.
                    if ((error as? StatusError)?.status != 0x6A83) failures.add(RawDataField("History Record $index", describe(error)))
                    break
                }
                if (payload.size != 23) {
                    sections.add(RawDataSection("Macau Pass Unrecognized History Record", listOf(
                        RawDataField("Record", "$index"), RawDataField("Payload", payload.hexString()))))
                    failures.add(RawDataField("History", "Unexpected record length"))
                    break
                }
                if (payload.any { it != 0.toByte() }) records.add(TransitApplicationRecord("transaction", 0x18, index, payload.hexString()))
            }
            val serial = info?.takeIf { it.size >= 20 }?.copyOfRange(16, 20)
                ?.takeIf { bytes -> bytes.any { it != 0.toByte() } && bytes.any { it != 0xFF.toByte() } }?.hexString()
            if (serial == null && balanceMinor == null && records.none { decodeTransaction(it.hex.hexToBytes()) != null }) return null
            // Without either identifier, different physical cards would share an empty wallet identity.
            if (serial == null && uid.isEmpty()) return null

            val fields = mutableListOf(ResultField("Brand", FAMILY), ResultField("Region", "Macau"), ResultField("Currency", "MOP"))
            serial?.let { fields.add(ResultField("Application Serial", it)) }
            if (info != null) {
                if (info.size >= 8) fields.add(ResultField("Issuer", info.copyOfRange(0, 8).hexString()))
                if (info.size >= 10) fields.add(ResultField("Application Version", "%02X".format(info[9])))
                for ((title, offset) in listOf("Issue Date" to 20, "Expiry Date" to 24)) {
                    if (info.size >= offset + 4) dateText(info.copyOfRange(offset, offset + 4))?.let { fields.add(ResultField(title, it)) }
                }
            }
            if (failures.isNotEmpty()) sections.add(RawDataSection("Macau Pass Read Status", failures))
            val snapshot = TransitCardSnapshot(
                technology = "ISO7816", cardFamily = FAMILY,
                identifierLabel = if (serial == null) "UID" else "Application Serial",
                identifierValue = serial ?: uid, rawIdentifierValue = uid.ifEmpty { serial.orEmpty() },
                selectedAID = APPLICATION_AID, balanceText = balanceMinor?.let { formatCardMoney(it, "MOP", 2) },
                balanceDetail = "Stored-value balance excluding the MOP 10 reserve.",
                realSerialNumber = serial, region = "Macau", resultFields = fields, rawSections = sections,
                rawTransactions = records.map { it.hex }, rawTransitHistory = emptyList(), scannedAt = scannedAt,
            )
            val macau = snapshot.copy(applications = listOf(TransitApplication.from(snapshot, records, "0446")))

            // Same connected card, separate currency and history. A failed or absent
            // companion must not discard the readable Macau purse.
            val selection = try {
                Iso7816Protocol.select(TUNION_AID, exchange)
            } catch (_: IOException) {
                null
            }
            val companion = selection?.let { Iso7816Decoder().readApplication(uid, it, scannedAt, exchange) }
            return companion?.let { TransitApplication.combine(listOf(macau, it)) } ?: macau
        }

        fun decodeTransaction(data: ByteArray): TransitTransaction? {
            if (data.size != 23 || data.all { it == 0.toByte() }) return null
            val date = timestamp(data.copyOfRange(16, 23)) ?: return null
            // The Macau-specific upstream field layout uses four bytes; its generic
            // parser drops byte 5. Retain the full field instead of truncating it.
            val tenths = uint(data, 5, 4)
            val type = data[9].toInt() and 0xFF
            val (amount, label, category) = when (type) {
                0x02 -> Triple(tenths * 10, "Top-up", TransactionCategory.topUp)
                0x06, 0x09 -> Triple(-tenths * 10, "Payment", TransactionCategory.payment)
                // Unknown event codes have no established credit/debit semantics.
                else -> Triple(0L, "Transaction (%02X)".format(type), TransactionCategory.unknown)
            }
            val time = data.copyOfRange(20, 23).hexString()
            return TransitTransaction(
                date = date, time = "${time.substring(0, 2)}:${time.substring(2, 4)}:${time.substring(4)}",
                amount = amount, terminalID = data.copyOfRange(10, 16).hexString(),
                recordNumber = uint(data, 0, 2).toInt(), type = label, category = category,
                rawData = data.hexString(), currencyCode = "MOP", fractionDigits = 2,
                issuerTimeZone = ISSUER_TIME_ZONE, amountIsSigned = true,
                amountKnown = category != TransactionCategory.unknown,
            )
        }

        private fun timestamp(bytes: ByteArray): Instant? {
            val digits = bytes.map { listOf((it.toInt() shr 4) and 0x0F, it.toInt() and 0x0F) }
            if (bytes.size != 7 || digits.any { pair -> pair.any { it > 9 } }) return null
            val values = digits.map { it[0] * 10 + it[1] }
            val year = values[0] * 100 + values[1]
            if (year !in 1900..2200) return null
            val local = runCatching { LocalDateTime.of(year, values[2], values[3], values[4], values[5], values[6]) }.getOrNull() ?: return null
            // Reject a wall-clock time that a historical transition skipped or repeated.
            val offset = ZoneId.of(ISSUER_TIME_ZONE).rules.getValidOffsets(local).singleOrNull() ?: return null
            return Instant.fromEpochSeconds(local.toEpochSecond(offset))
        }

        private fun dateText(data: ByteArray): String? {
            if (timestamp(data + byteArrayOf(0, 0, 0)) == null) return null
            val raw = data.hexString()
            return "${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6)}"
        }

        private fun uint(data: ByteArray, start: Int, length: Int): Long =
            (start until start + length).fold(0L) { value, index -> (value shl 8) or (data[index].toLong() and 0xFF) }

        private class StatusError(val status: Int) : Exception("Card status %04X".format(status))
        private class ReadLimitError : Exception("Response exceeded the read limit")
        private class MalformedResponseError : Exception("Response is missing its status word")

        private fun describe(error: Throwable) = error.message ?: error.javaClass.simpleName

        /** Returns a 9000 payload, following one 6Cxx correction and bounded 61xx continuations. */
        private fun transmit(command: ByteArray, exchange: (ByteArray) -> ByteArray): ByteArray {
            var current = command
            val result = ByteArrayOutputStream()
            var corrected = false
            for (attempt in 0 until MAX_COMMANDS) {
                val response = exchange(current)
                if (response.size < 2) throw MalformedResponseError()
                val sw1 = response[response.size - 2].toInt() and 0xFF
                val sw2 = response.last().toInt() and 0xFF
                if (sw1 == 0x6C && !corrected) {
                    // Every command here ends with a short Le, where 00 means 256.
                    current = current.copyOf().also { it[it.lastIndex] = sw2.toByte() }
                    corrected = true
                    continue
                }
                if (!(sw1 == 0x90 && sw2 == 0) && sw1 != 0x61) throw StatusError(sw1 shl 8 or sw2)
                if (result.size() + response.size - 2 > MAX_RESPONSE_BYTES) throw ReadLimitError()
                result.write(response, 0, response.size - 2)
                if (sw1 == 0x90) return result.toByteArray()
                current = byteArrayOf(0, 0xC0.toByte(), 0, 0, sw2.toByte())
                corrected = false
            }
            throw ReadLimitError()
        }
    }
}
