// SPDX-License-Identifier: GPL-3.0-or-later
// Clipper format adapted from FareBot / Metrodroid at dc09f6f014ea3675b64bcd38335b4b78d77fa374.
// Copyright (C) 2014-2016, 2025 Eric Butler, 2014 Bao-Long Nguyen-Trong,
// 2016, 2018 Michael Farrell, 2018 Google. Thanks to Anonymous Contributor.
package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.data.TransitTransaction
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexString
import java.io.InterruptedIOException
import java.math.BigDecimal
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.datetime.Instant

/** Catalog injection keeps protocol records independent of Android assets and database wiring. */
interface ClipperLookup {
    fun agencyName(agency: Int): String = "Agency 0x%X".format(agency)
    fun defaultMode(agency: Int): Int = 0
    fun stationCode(agency: Int, station: Int): String? = null
    fun stationName(agency: Int, station: Int, isEnd: Boolean): String? {
        if (agency in setOf(6, 11, 12, 25)) {
            if (station == 0xFFFF) return "End of line"
            if (agency != 25) return "Zone $station"
        }
        if (station == if (isEnd) 0xFFFF else 0) return null
        return "0x%X/0x%X".format(agency, station)
    }
    fun routeName(agency: Int, route: Int): String? =
        if (route == 0 || route == 0xFFFF) null else "Route 0x%X".format(route)

    object Numeric : ClipperLookup
}

/** Probe after implicit CEPAS, and before the older generic stored-value Clipper adapter. */
class ClipperDecoder(private val lookup: ClipperLookup = ClipperLookup.Numeric) : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val connection = IsoDep.get(tag) ?: return null
        return connection.use { card ->
            card.connect()
            card.timeout = 2500
            read(tag.id, scannedAt, card::transceive)
        }
    }

    /** Exchange returns the complete APDU reply, including SW1/SW2. */
    fun read(identifier: ByteArray, scannedAt: Instant, exchange: (ByteArray) -> ByteArray): TransitCardSnapshot {
        val reader = ClipperDesfireProtocol(exchange)
        reader.select(byteArrayOf(0x90.toByte(), 0x11, 0xF2.toByte()))
        val files = mutableMapOf(8 to reader.readFile(8), 2 to reader.readFile(2))
        val unavailable = mutableListOf<Int>()
        for (number in listOf(1, 4, 14)) {
            try {
                files[number] = reader.readFile(number)
            } catch (error: InterruptedIOException) {
                throw error
            } catch (_: java.io.IOException) {
                unavailable.add(number)
            }
        }
        return snapshot(files, identifier, scannedAt, unavailable)
    }

    companion object {
        const val APPLICATION_ID = "9011F2"
        const val EPOCH_OFFSET_SECONDS = 2_208_988_800L
        const val ISSUER_TIME_ZONE = "America/Los_Angeles"

        /** Upgrade only complete legacy DFSV Clipper trip/reload envelopes; preserve everything else verbatim. */
        fun canonicalHistoryRecord(raw: String): String {
            if (raw.length != 86 || raw.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) return raw
            val bytes = raw.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            if (!bytes.copyOfRange(0, 6).contentEquals(byteArrayOf(0x44, 0x46, 0x53, 0x56, 1, 5)) ||
                bytes[9] != 0.toByte() || bytes[10] != 32.toByte()) return raw
            val file = when (bytes[6].toInt() and 255) {
                2 -> 4
                3 -> 14
                else -> return raw
            }
            return (byteArrayOf(file.toByte()) + bytes.copyOfRange(11, 43)).hexString()
        }

        fun snapshot(
            files: Map<Int, ByteArray>, identifier: ByteArray, scannedAt: Instant,
            unavailable: List<Int> = emptyList(),
        ): TransitCardSnapshot {
            val serial = files[8]?.takeIf { it.size >= 5 } ?: throw ClipperDesfireProtocol.ReadException()
            val balance = files[2]?.takeIf { it.size >= 20 } ?: throw ClipperDesfireProtocol.ReadException()
            val number = unsigned(serial, 1, 4).toString()
            val cents = unsigned(balance, 18, 2).toShort().toLong()
            val fields = mutableListOf(ResultField("Card Number", number), ResultField("Card Type", "Clipper (DESFire)"),
                ResultField("Region", "San Francisco Bay Area"), ResultField("Currency", "USD"))
            files[1]?.takeIf { it.size >= 10 }?.let {
                val days = unsigned(it, 8, 2)
                if (days > 0) fields.add(ResultField("Expiry Date", dateText(days * 86400)))
            }
            val trips = records(files[14], 14)
            val refills = records(files[4], 4)
            val sections = files.toSortedMap().map { (file, data) ->
                RawDataSection("Clipper File %02X".format(file), listOf(RawDataField("Payload", data.hexString())))
            }.toMutableList()
            if (unavailable.isNotEmpty()) sections.add(RawDataSection("Clipper Read Status", listOf(
                RawDataField("Unavailable Files", unavailable.joinToString(", ") { "%02X".format(it) }),
            )))
            return TransitCardSnapshot(
                technology = "ISO7816", cardFamily = "Clipper", identifierLabel = "Card Number",
                identifierValue = number, rawIdentifierValue = identifier.takeIf { it.isNotEmpty() }?.hexString() ?: number,
                selectedAID = APPLICATION_ID, balanceText = "USD ${BigDecimal.valueOf(cents, 2).toPlainString()}",
                balanceDetail = "Clipper stored-value balance.", realSerialNumber = number, region = "San Francisco Bay Area",
                resultFields = fields, rawSections = sections, rawTransactions = trips + refills,
                rawTransitHistory = trips, scannedAt = scannedAt,
            )
        }

        /** File prefix prevents equal-sized reload and trip records becoming interchangeable. */
        fun records(fileData: ByteArray?, file: Int): List<String> {
            if (fileData == null || fileData.size % 32 != 0 || file !in setOf(4, 14)) return emptyList()
            return (fileData.size - 32 downTo 0 step 32).mapNotNull { offset ->
                val record = byteArrayOf(file.toByte()) + fileData.copyOfRange(offset, offset + 32)
                if (decodeRecord(record) == null) null else record.hexString()
            }
        }

        fun decodeTransaction(
            data: ByteArray, context: List<ByteArray>, index: Int,
            lookup: ClipperLookup = ClipperLookup.Numeric,
        ): TransitTransaction? {
            val transaction = decodeRecord(data, lookup) ?: return null
            val timestamp = tripEntryTimestamp(data)
            if (timestamp != null && index in context.indices) {
                val matches = context.indices.filter { tripEntryTimestamp(context[it]) == timestamp }
                val preferred = matches.firstOrNull { unsigned(context[it], 17, 4) != 0L } ?: matches.firstOrNull()
                if (preferred != index) return null
            }
            return transaction
        }

        /** The entry timestamp is shared by provisional/completed halves, never reloads. */
        fun tripEntryTimestamp(data: ByteArray): Long? =
            if (data.size == 33 && data[0] == 14.toByte()) unsigned(data, 13, 4).takeIf { it != 0L } else null

        fun decodeRecord(data: ByteArray, lookup: ClipperLookup = ClipperLookup.Numeric): TransitTransaction? {
            if (data.size != 33) return null
            val file = data[0].toInt() and 255
            if (file !in setOf(4, 14)) return null
            val record = data.copyOfRange(1, 33)
            val agency = unsigned(record, 2, 2).toInt()
            val seconds = unsigned(record, if (file == 4) 4 else 12, 4)
            if (seconds == 0L || (file == 14 && agency == 0)) return null
            val date = Instant.fromEpochSeconds(seconds - EPOCH_OFFSET_SECONDS)
            val agencyName = lookup.agencyName(agency)
            if (file == 4) return TransitTransaction(
                date = date, time = timeText(date), amount = unsigned(record, 14, 2),
                terminalID = unsigned(record, 8, 4).toString(), type = "Top-up", category = TransactionCategory.topUp,
                location = agencyName, rawData = data.hexString(), currencyCode = "USD", fractionDigits = 2,
                issuerTimeZone = ISSUER_TIME_ZONE, amountIsSigned = true,
            )
            val from = unsigned(record, 20, 2).toInt()
            val to = unsigned(record, 22, 2).toInt()
            val route = unsigned(record, 28, 2).toInt()
            val mode = unsigned(record, 30, 2).toInt()
            val (category, modeName) = when (mode) {
                0x61, 0x75, 0x77 -> TransactionCategory.bus to "Bus"
                0x6F -> TransactionCategory.train to "Metro"
                0x78 -> TransactionCategory.train to "Train"
                0x73 -> ferryCategory() to "Ferry"
                0x62 -> if (agency == 0x19 || agency == 0x1B) ferryCategory() to "Ferry"
                    else TransactionCategory.train to if (agency == 6 || agency == 12) "Train" else "Tram"
                else -> TransactionCategory.unknown to "Transit"
            }
            return TransitTransaction(
                date = date, time = timeText(date), amount = -unsigned(record, 6, 2),
                terminalID = vehicleName(unsigned(record, 10, 2).toInt()), type = "$agencyName - $modeName",
                category = category, location = listOfNotNull(agencyName, lookup.routeName(agency, route)).joinToString(" - "),
                entryStation = lookup.stationName(agency, from, false), exitStation = lookup.stationName(agency, to, true),
                entryStationCode = lookup.stationCode(agency, from), exitStationCode = lookup.stationCode(agency, to),
                rawData = data.hexString(), currencyCode = "USD", fractionDigits = 2,
                issuerTimeZone = ISSUER_TIME_ZONE, amountIsSigned = true,
            )
        }

        fun vehicleName(number: Int): String? = when (number) {
            0, 0xFFFF -> null
            in 1..9999 -> number.toString()
            else -> "${number / 10}${(number % 10 + 9).toString(16).uppercase(Locale.ROOT)}"
        }

        internal fun unsigned(data: ByteArray, offset: Int, length: Int): Long =
            (offset until offset + length).fold(0L) { value, index -> (value shl 8) or (data[index].toLong() and 255) }

        internal fun ferryCategory(): TransactionCategory =
            TransactionCategory.entries.firstOrNull { it.name == "ferry" } ?: TransactionCategory.unknown

        internal fun timeText(date: Instant): String = DateTimeFormatter.ofPattern("HH:mm:ss", Locale.ROOT)
            .withZone(ZoneId.of(ISSUER_TIME_ZONE)).format(java.time.Instant.ofEpochSecond(date.epochSeconds))

        internal fun dateText(seconds: Long): String = DateTimeFormatter.ISO_LOCAL_DATE.withZone(ZoneId.of("UTC"))
            .format(java.time.Instant.ofEpochSecond(seconds - EPOCH_OFFSET_SECONDS))
    }
}
