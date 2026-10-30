// SPDX-License-Identifier: GPL-3.0-or-later
// Clipper ticket format adapted from FareBot / Metrodroid at dc09f6f014ea3675b64bcd38335b4b78d77fa374.
// Copyright 2018 Google, 2025 Eric Butler.
package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.MifareUltralight
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.data.TransitTransaction
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexString
import java.io.IOException
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.datetime.Instant

/** Four-page READ operations only; no credentials, authentication or card writes. */
class ClipperUltralightDecoder(private val lookup: ClipperLookup = ClipperLookup.Numeric) : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = MifareUltralight.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val connection = MifareUltralight.get(tag) ?: return null
        return connection.use { card ->
            card.connect()
            read(tag.id, scannedAt, card::readPages)
        }
    }

    /** The callback reads exactly four pages (16 bytes) at the requested page. */
    fun read(identifier: ByteArray, scannedAt: Instant, readPages: (Int) -> ByteArray): TransitCardSnapshot? {
        val header = readPages(4)
        if (header.size != 16 || header[0] != 0x13.toByte()) return null
        val first = readPages(0)
        val middle = readPages(8)
        val last = readPages(12)
        if (first.size != 16 || middle.size != 16 || last.size != 16) throw IOException("Incomplete Clipper ticket pages")
        return snapshot(first + header + middle + last, identifier, scannedAt, lookup)
    }

    companion object {
        fun snapshot(
            data: ByteArray, identifier: ByteArray, scannedAt: Instant,
            lookup: ClipperLookup = ClipperLookup.Numeric,
        ): TransitCardSnapshot? {
            if (data.size != 64 || data[16] != 0x13.toByte()) return null
            val number = ClipperDecoder.unsigned(data, 12, 4).toString()
            val baseDays = ClipperDecoder.unsigned(data, 22, 2)
            val product = ClipperDecoder.unsigned(data, 20, 2).toInt()
            val raw = listOf(24, 44).mapNotNull { offset ->
                val event = data.copyOfRange(offset, offset + 20)
                if (event.all { it == 0.toByte() }) null else data.copyOfRange(22, 24) + event
            }
            val events = raw.mapNotNull(TicketEvent::parse)
            val latest = events.fold<TicketEvent, TicketEvent?>(null) { current, event ->
                if (current == null || event.isNewerThan(current)) event else current
            }
            val passenger = when (data[17].toInt() and 255) {
                0x04 -> "Adult"; 0x44 -> "Senior"; 0x84 -> "RTC"; 0xC4 -> "Youth"
                else -> "0x%02X".format(data[17].toInt() and 255)
            }
            val productName = if (product and 15 in 3..10) {
                listOf("Adult", "Senior", "RTC", "Youth")[((product and 15) - 3) / 2] +
                    if (product and 1 == 1) " single ride" else " return"
            } else "0x%04X".format(product)
            val fields = mutableListOf(ResultField("Card Number", number), ResultField("Card Type", "Clipper Ticket"),
                ResultField("Ticket Type", passenger), ResultField("Product", productName),
                ResultField("Agency", lookup.agencyName(if (product shr 4 == 0x21) 0x12 else product shr 4)),
                ResultField("Currency", "USD"))
            if (baseDays > 0) fields.add(ResultField("Expiry Date", ClipperDecoder.dateText(baseDays * 86400)))
            if (baseDays > 89) fields.add(ResultField("Issue Date", ClipperDecoder.dateText((baseDays - 89) * 86400)))
            if (latest != null) {
                fields.add(ResultField("Trips Remaining", latest.remaining.toString()))
                if (latest.transferMinutes > 0) {
                    val seconds = (latest.minutes + latest.transferMinutes) * 60 - ClipperDecoder.EPOCH_OFFSET_SECONDS
                    fields.add(ResultField("Transfer Expiry", DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.ROOT)
                        .withZone(ZoneId.of(ClipperDecoder.ISSUER_TIME_ZONE)).format(java.time.Instant.ofEpochSecond(seconds))))
                }
            }
            return TransitCardSnapshot(
                technology = "MIFARE Ultralight", cardFamily = "Clipper Ticket", identifierLabel = "Card Number",
                identifierValue = number, rawIdentifierValue = identifier.takeIf { it.isNotEmpty() }?.hexString() ?: number,
                realSerialNumber = number, region = "San Francisco Bay Area", resultFields = fields,
                rawSections = listOf(RawDataSection("Clipper Ticket Pages 0-15", listOf(RawDataField("Payload", data.hexString())))),
                rawTransactions = emptyList(), rawTransitHistory = raw.map { it.hexString() }, scannedAt = scannedAt,
            )
        }

        fun decodeTransaction(data: ByteArray, lookup: ClipperLookup = ClipperLookup.Numeric): TransitTransaction? {
            val event = TicketEvent.parse(data)?.takeIf { it.type != 1 } ?: return null
            val date = Instant.fromEpochSeconds(event.minutes * 60 - ClipperDecoder.EPOCH_OFFSET_SECONDS)
            val category = when (lookup.defaultMode(event.agency)) {
                1 -> TransactionCategory.bus
                2, 3, 4 -> TransactionCategory.train
                5 -> ClipperDecoder.ferryCategory()
                else -> TransactionCategory.unknown
            }
            return TransitTransaction(
                date = date, time = ClipperDecoder.timeText(date), amount = 0,
                type = lookup.agencyName(event.agency), category = category,
                entryStation = lookup.stationName(event.agency, event.station, false),
                entryStationCode = lookup.stationCode(event.agency, event.station),
                rawData = data.hexString(), currencyCode = "USD", fractionDigits = 2,
                issuerTimeZone = ClipperDecoder.ISSUER_TIME_ZONE, amountIsSigned = true, amountKnown = false,
            )
        }
    }

    data class TicketEvent(
        val minutes: Long, val transferMinutes: Int, val sequence: Int, val balanceSequence: Int,
        val remaining: Int, val station: Int, val agency: Int, val type: Int,
    ) {
        fun isNewerThan(other: TicketEvent): Boolean =
            if (balanceSequence != other.balanceSequence) (balanceSequence - other.balanceSequence) and 8 == 0
            else (sequence - other.sequence) and 64 == 0

        companion object {
            fun parse(data: ByteArray): TicketEvent? {
                if (data.size != 22 || data.drop(2).all { it == 0.toByte() }) return null
                fun bits(offset: Int, count: Int): Int = (offset until offset + count).fold(0) { result, bit ->
                    (result shl 1) or ((data[2 + bit / 8].toInt() ushr (7 - bit % 8)) and 1)
                }
                return TicketEvent(
                    minutes = ClipperDecoder.unsigned(data, 0, 2) * 1440 - bits(24, 17),
                    transferMinutes = bits(100, 10), sequence = bits(0, 7), balanceSequence = bits(80, 4),
                    remaining = bits(84, 6), station = bits(41, 17), agency = bits(68, 5), type = bits(7, 17),
                )
            }
        }
    }
}
