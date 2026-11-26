// SPDX-License-Identifier: GPL-3.0-or-later
// CharlieCard (Boston MBTA) format adapted from Metrodroid.
// Copyright 2018 Google, 2015-2018 Michael Farrell.
// See docs/decoding/charliecard.md.
package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.data.TransitTransaction
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import java.math.BigDecimal
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.datetime.Instant

/**
 * CharlieCard of the Massachusetts Bay Transportation Authority (Boston), a
 * MIFARE Classic 1K card. Its sectors are protected with keys that are public
 * (shipped in the Proxmark3 and Metrodroid dictionaries); CardBal bundles those
 * keys to read the card and never authenticates to write.
 */
object CharlieCardProtocol {
    const val NAME = "CharlieCard"
    const val REGION = "Boston"
    const val TIME_ZONE = "America/New_York"

    /** Public MBTA CharlieCard keys, tried per sector as key A and key B. */
    val KEYS: List<ByteArray> = listOf(
        "3060206F5B0A", "5EC39B022F2B", "3A09594C8587", "F1B9F5669CC8", "F662248E7E89",
        "62387B8D250D", "F238D78FF48F", "9DC282D46217", "AFD0BA94D624", "92EE4DC87191",
        "B35A0E4ACC09", "756EF55E2507", "447AB7FD5A6B", "932B9CB730EF", "1F1A0A111B5B",
        "AD9E0A1CA2F7", "D58023BA2BDC", "62CED42A6D87", "2548A443DF28", "2ED3B15E7C0F",
        "F66224EE1E89",
    ).map { it.hexToBytes() }

    /**
     * Sector 0 is read with these known keys, which also identify the card.
     * Either may be key A or key B, so both are tried in both roles.
     */
    val SECTOR0_KEYS: List<ByteArray> = listOf("3060206F5B0A", "F1B9F5669CC8").map { it.hexToBytes() }

    val REQUIRED_SECTORS = listOf(0, 2, 3, 6, 7, 8)

    private val EPOCH_SECONDS = LocalDate.of(2003, 1, 1).atStartOfDay(ZoneId.of(TIME_ZONE)).toEpochSecond()

    private fun beInt(data: ByteArray, offset: Int, length: Int): Int =
        (offset until offset + length).fold(0) { value, index -> (value shl 8) or (data[index].toInt() and 255) }

    private fun beLong(data: ByteArray, offset: Int, length: Int): Long =
        (offset until offset + length).fold(0L) { value, index -> (value shl 8) or (data[index].toLong() and 255) }

    private fun bits(data: ByteArray, offset: Int, count: Int): Int =
        (offset until offset + count).fold(0) { value, bit ->
            (value shl 1) or ((data[bit / 8].toInt() ushr (7 - bit % 8)) and 1)
        }

    /** Signed half-cent price: 0x8000 marks a negative value, divided by two. */
    fun price(data: ByteArray, offset: Int): Int {
        var value = beInt(data, offset, 2)
        if (value and 0x8000 != 0) value = -(value and 0x7FFF)
        return value / 2
    }

    fun date(minutes: Int): Instant = Instant.fromEpochSeconds(EPOCH_SECONDS + minutes.toLong() * 60)

    private fun dateText(date: Instant, pattern: String): String =
        DateTimeFormatter.ofPattern(pattern, Locale.ROOT).withZone(ZoneId.of(TIME_ZONE))
            .format(java.time.Instant.ofEpochSecond(date.epochSeconds))

    /** `sectors[s]` holds the three data blocks of sector `s`; trailers are never read. */
    fun snapshot(sectors: Map<Int, List<ByteArray>>, identifier: ByteArray, scannedAt: Instant): TransitCardSnapshot? {
        val sector0 = sectors[0]?.takeIf { it.size == 3 } ?: return null
        val sector2 = sectors[2]?.takeIf { it.size == 3 } ?: return null
        val sector3 = sectors[3]?.takeIf { it.size == 3 } ?: return null

        val serial = beLong(sector0[0], 0, 4)
        val serialText = "5-$serial"

        val balanceSector = if (bits(sector2[0], 81, 16) > bits(sector3[0], 81, 16)) sector2 else sector3
        val cents = price(balanceSector[1], 5)
        val start = date(beInt(balanceSector[0], 6, 3))

        val trips = mutableListOf<ByteArray>()
        for (i in 0 until 12) {
            val block = sectors[6 + i / 6]?.getOrNull((i / 2) % 3) ?: continue
            val offset = 7 * (i % 2)
            if (block.size < offset + 7 || beInt(block, offset, 4) == 0) continue
            trips.add(block.copyOfRange(offset, offset + 7))
        }

        val startZoned = java.time.Instant.ofEpochSecond(start.epochSeconds).atZone(ZoneId.of(TIME_ZONE))
        var expiry = startZoned.plusYears(11).minusDays(1)
        val lastTrip = trips.maxOfOrNull { beInt(it, 0, 3) }
        if (lastTrip != null) {
            val candidate = java.time.Instant.ofEpochSecond(date(lastTrip).epochSeconds)
                .atZone(ZoneId.of(TIME_ZONE)).plusYears(2)
            if (candidate.isBefore(expiry)) expiry = candidate
        }
        val expiryText = expiry.format(DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.ROOT))

        val fields = mutableListOf(
            ResultField("Card Number", serialText),
            ResultField("Card Type", NAME),
            ResultField("Region", REGION),
            ResultField("Currency", "USD"),
            ResultField("Issue Date", dateText(start, "yyyy-MM-dd")),
            ResultField("Expiry Date", expiryText),
        )
        sectors[8]?.firstOrNull()?.let { block ->
            val second = beLong(block, 0, 4)
            if (second != 0L && second != 0xFFFFFFFFL) {
                fields.add(ResultField("Second Card Number", "A" + "%010d".format(second)))
            }
        }

        val sections = sectors.keys.sorted().map { index ->
            RawDataSection("CharlieCard Sector $index",
                listOf(RawDataField("Payload", sectors.getValue(index).reduce(ByteArray::plus).hexString())))
        }
        return TransitCardSnapshot(
            technology = "MIFARE Classic", cardFamily = NAME, identifierLabel = "Card Number",
            identifierValue = serialText, rawIdentifierValue = identifier.takeIf { it.isNotEmpty() }?.hexString() ?: serialText,
            balanceText = "USD ${BigDecimal.valueOf(cents.toLong(), 2).toPlainString()}",
            balanceDetail = "CharlieCard stored-value balance.", realSerialNumber = serialText, region = REGION,
            resultFields = fields, rawSections = sections, rawTransactions = emptyList(),
            rawTransitHistory = trips.map { it.hexString() }, scannedAt = scannedAt,
        )
    }

    /** A seven-byte trip record: `[timestamp(3)][validator(2)][fare(2)]`. */
    fun decodeTransaction(data: ByteArray): TransitTransaction? {
        if (data.size != 7 || beInt(data, 0, 4) == 0) return null
        val date = date(beInt(data, 0, 3))
        val validator = beInt(data, 3, 2)
        val fare = price(data, 5)
        val (category, type) = when (validator and 7) {
            0 -> TransactionCategory.purchase to "Ticket Machine"
            1 -> TransactionCategory.bus to "Bus"
            else -> TransactionCategory.train to "Subway"
        }
        val station = validator shr 3
        return TransitTransaction(
            date = date, time = dateText(date, "HH:mm"), amount = -fare.toLong(),
            terminalID = if (station != 0) station.toString() else null, type = type, category = category,
            rawData = data.hexString(), currencyCode = "USD", fractionDigits = 2,
            issuerTimeZone = TIME_ZONE, amountIsSigned = true,
        )
    }
}
