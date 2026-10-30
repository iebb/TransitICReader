package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.NfcF
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.formatFeliCaId
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import java.text.NumberFormat
import java.util.Locale

class JapaneseICDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = NfcF.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val nfc = NfcF.get(tag) ?: return null
        FeliCaTransceiver(nfc).use { felica ->
            felica.connect()
            KmtProtocol.read(felica::polling, felica::readWithoutEncryption)?.let { kmt ->
                return kmtSnapshot(felica, kmt, scannedAt)
            }
            for (profile in FeliCaProfile.entries) {
                if (!felica.polling(profile.systemCode)) continue
                val block = felica.readWithoutEncryption(profile.balanceService, 0) ?: continue
                val parsed = profile.parseBalance(block, scannedAt) ?: continue
                val systemCodes = felica.requestSystemCodes().ifEmpty { listOf(profile.systemCode) }
                val detected = profile.detectedBrand(systemCodes)
                val transactions = when (profile) {
                    FeliCaProfile.JapanTransit, FeliCaProfile.IruCa, FeliCaProfile.Paspy, FeliCaProfile.Sapica -> readService(felica, "0F09", 20)
                    FeliCaProfile.Octopus -> readService(felica, "1701", 10, start = 1)
                    FeliCaProfile.Waon -> readPairedServiceRecords(felica, "0B68", 6)
                    FeliCaProfile.Edy -> readService(felica, "0F17", 6)
                    FeliCaProfile.Nanaco -> readService(felica, "4F56", 5)
                    FeliCaProfile.Okica -> readService(felica, "8F02", 20)
                    FeliCaProfile.Ryuto -> readService(felica, "8F89", 20)
                }
                val transitHistory = if (profile in setOf(FeliCaProfile.JapanTransit, FeliCaProfile.IruCa, FeliCaProfile.Paspy, FeliCaProfile.Sapica)) {
                    readService(felica, "8F10", 20) + readService(felica, "CB10", 20)
                } else if (profile == FeliCaProfile.Okica) {
                    readService(felica, "0F05", 3) + readService(felica, "0B06", 2)
                } else {
                    emptyList()
                }
                val extraFields = when (profile) {
                    FeliCaProfile.Waon -> waonExtraFields(felica)
                    FeliCaProfile.Edy -> buildList {
                        felica.readWithoutEncryption("0B11", 0)?.let { data ->
                            JapaneseCardFormats.number(data, 2)?.let { add(ResultField("Edy ID", it)) }
                            val clock=JapaneseCardFormats.uint(data,10,4)
                            val seconds=(clock and 0x1ffff).toInt()
                            if(clock!=0L && seconds<86400) {
                                val day=java.time.LocalDate.of(2000,1,1).plusDays(clock shr 17)
                                JapaneseCardFormats.date(day.year,day.monthValue,day.dayOfMonth,seconds/3600,seconds/60%60,seconds%60)?.let { date ->
                                    val formatted=java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss").withZone(java.time.ZoneId.of("Asia/Tokyo")).format(java.time.Instant.ofEpochMilli(date.toEpochMilliseconds()))
                                    add(ResultField("Issue Date","$formatted JST"))
                                }
                            }
                        }
                    }
                    FeliCaProfile.Nanaco -> buildList {
                        JapaneseCardFormats.number(felica.readWithoutEncryption("8B55", 0))?.let { add(ResultField("nanaco Number", it)) }
                        felica.readWithoutEncryption("0B56", 1)?.takeIf { it.size == 16 }?.let { add(ResultField("Points", "${JapaneseCardFormats.uint(it, 0, 3, true)} pts")) }
                        felica.readWithoutEncryption("CB55", 0)?.takeIf { it.size == 16 }?.let {
                            JapaneseCardFormats.packedDate(JapaneseCardFormats.uint(it, 0, 2).toInt())?.let { day -> add(ResultField("Last Use Date", day)) }
                            JapaneseCardFormats.packedDate(JapaneseCardFormats.uint(it, 4, 2).toInt())?.let { day -> add(ResultField("Issue Date", day)) }
                        }
                    }
                    else -> emptyList()
                }

                return TransitCardSnapshot(
                    technology = "FeliCa",
                    cardFamily = detected,
                    identifierLabel = when (profile) { FeliCaProfile.Waon -> "WAON No."; FeliCaProfile.Nanaco -> "nanaco No."; FeliCaProfile.Edy -> "Edy ID"; else -> "IDm" },
                    identifierValue = extraFields.firstOrNull { it.title in setOf("WAON Number", "nanaco Number", "Edy ID") }?.value ?: formatFeliCaId(felica.idmHex),
                    rawIdentifierValue = felica.idmHex,
                    pmm = null,
                    realSerialNumber = extraFields.firstOrNull { it.title in setOf("WAON Number", "nanaco Number", "Edy ID") }?.value,
                    systemCode = profile.systemCode,
                    balanceText = parsed.balanceText,
                    balanceDetail = parsed.detail,
                    resultFields = listOf(
                        ResultField("Detected Type", detected),
                        ResultField("Card Number (IDm)", formatFeliCaId(felica.idmHex)),
                    ) + extraFields,
                    rawSections = listOf(
                        RawDataSection(
                            "Tag",
                            listOf(
                                RawDataField("Technology", "FeliCa"),
                                RawDataField("IDm", formatFeliCaId(felica.idmHex)),
                                RawDataField("System Codes", systemCodes.joinToString(", ")),
                            ),
                        ),
                        RawDataSection(
                            "Decoded Balance",
                            parsed.rawFields + RawDataField("Raw Block", block.hexString()),
                        ),
                    ),
                    rawTransactions = transactions,
                    rawTransitHistory = transitHistory,
                    scannedAt = scannedAt,
                )
            }
        }
        return null
    }

    private fun kmtSnapshot(felica: FeliCaTransceiver, card: KmtProtocol.Snapshot, scannedAt: Instant): TransitCardSnapshot {
        val systemCodes = felica.requestSystemCodes().ifEmpty { listOf(KmtProtocol.SYSTEM_CODE) }
        val amount = NumberFormat.getIntegerInstance(Locale.forLanguageTag("id-ID")).format(card.balance.amountIdr)
        val identifier = formatFeliCaId(felica.idmHex)
        val fields = buildList {
            add(ResultField("Detected Type", "Kartu Multi Trip"))
            add(ResultField("Card Number (IDm)", identifier))
            card.cardNumber?.let { add(ResultField("KMT Card Number", it)) }
        }
        val sections = buildList {
            add(RawDataSection("Tag", listOf(
                RawDataField("Technology", "FeliCa"),
                RawDataField("IDm", identifier),
                RawDataField("System Codes", systemCodes.joinToString(", ")),
            )))
            add(RawDataSection("Decoded Balance", listOf(
                RawDataField("Balance (IDR)", card.balance.amountIdr.toString()),
                RawDataField("Last Transaction Amount (IDR)", card.balance.lastTransactionAmountIdr.toString()),
                RawDataField("Transaction Counter", card.balance.transactionCounter.toString()),
                RawDataField("Raw Block", card.balanceBlock.hexString()),
            )))
            card.identifierBlock?.let { add(RawDataSection("KMT Identifier", listOf(RawDataField("Raw Block", it.hexString())))) }
            add(RawDataSection("KMT History", listOf(
                RawDataField("History", "Preserved as raw records; dates are not verified."),
            )))
        }
        return TransitCardSnapshot(
            technology = "FeliCa", cardFamily = "KMT", identifierLabel = "IDm",
            identifierValue = identifier, rawIdentifierValue = felica.idmHex,
            pmm = null, systemCode = KmtProtocol.SYSTEM_CODE,
            balanceText = "Rp $amount", balanceDetail = "KMT stored value in whole Indonesian rupiah.",
            realSerialNumber = card.cardNumber, resultFields = fields, rawSections = sections,
            rawTransactions = card.historyBlocks.map { it.hexString() }, rawTransitHistory = emptyList(),
            scannedAt = scannedAt,
        )
    }

    private fun readService(felica: FeliCaTransceiver, service: String, limit: Int, start: Int = 0): List<String> {
        val records = mutableListOf<String>()
        for (i in start until start + limit) {
            val block = felica.readWithoutEncryption(service, i) ?: break
            if (block.size != 16) break
            if (block.all { it == 0.toByte() }) continue
            records.add(block.hexString())
        }
        return records
    }

    private fun readPairedServiceRecords(felica: FeliCaTransceiver, service: String, blockLimit: Int): List<String> {
        val records = mutableListOf<String>()
        for (index in 0 until blockLimit step 2) {
            val first = felica.readWithoutEncryption(service, index) ?: break
            val second = felica.readWithoutEncryption(service, index + 1) ?: break
            if (first.size != 16 || second.size != 16) break
            val record = first + second
            if (record.any { it != 0.toByte() }) records.add(record.hexString())
        }
        return records
    }

    private fun waonExtraFields(felica: FeliCaTransceiver): List<ResultField> {
        val fields = mutableListOf<ResultField>()
        felica.readWithoutEncryption("4F68", 0)?.let { numberBlock ->
            fields.add(ResultField("WAON Number", numberBlock.take(8).toByteArray().hexString()))
        }
        felica.readWithoutEncryption("4B68", 0)?.let { pointsBlock ->
            if (pointsBlock.size >= 3) {
                val points = (pointsBlock[0].toInt() and 0xff) or
                    ((pointsBlock[1].toInt() and 0xff) shl 8) or
                    ((pointsBlock[2].toInt() and 0xff) shl 16)
                fields.add(ResultField("Points", "$points pts"))
            }
        }
        return fields
    }
}

private data class ParsedBalance(
    val balanceText: String,
    val detail: String,
    val rawFields: List<RawDataField>,
)

private enum class FeliCaProfile(
    val displayName: String,
    val systemCode: String,
    val balanceService: String,
    val historyService: String? = null,
) {
    JapanTransit("Japan Transit IC", "0003", "8B00", "0F09"),
    IruCa("IruCa", "80DE", "8B00", "0F09"),
    Paspy("PASPY", "8592", "8B00", "0F09"),
    Sapica("SAPICA", "865E", "8B00", "0F09"),
    Okica("OKICA", "8FC1", "8F02", "8F02"),
    Ryuto("Ryuto", "8B5D", "8F89", "8F89"),
    Octopus("Octopus", "8008", "1701", "1701"),
    Edy("Rakuten Edy", "FE00", "1713", "0F17"),
    Waon("WAON", "FE00", "1768", "0B68"),
    Nanaco("nanaco", "FE00", "9755", "4F56");

    fun parseBalance(block: ByteArray, scannedAt: Instant): ParsedBalance? {
        if (block.size < 16) return null
        return when (this) {
            JapanTransit, IruCa, Paspy, Sapica -> {
                val balance = (block[11].toInt() and 0xff) or ((block[12].toInt() and 0xff) shl 8)
                ParsedBalance(
                    "¥%,d".format(balance),
                    "Parsed from bytes 11-12 in little-endian order.",
                    listOf(RawDataField("Balance", balance.toString()), RawDataField("Bytes 11-12", "%02X%02X".format(block[11], block[12]))),
                )
            }
            Okica, Ryuto -> {
                val amount = if (this == Okica) JapaneseCardFormats.uint(block, 10, 2, true) else JapaneseCardFormats.uint(block, 14, 2)
                if (this == Ryuto && JapaneseCardFormats.ryuto(block, block.hexString()) == null) return null
                ParsedBalance("¥%,d".format(amount), "Stored balance from the latest transaction.", listOf(RawDataField("Balance", amount.toString())))
            }
            Octopus -> {
                val raw = ((block[0].toInt() and 0xff) shl 24) or
                    ((block[1].toInt() and 0xff) shl 16) or
                    ((block[2].toInt() and 0xff) shl 8) or
                    (block[3].toInt() and 0xff)
                val offset = octopusOffset(scannedAt)
                val value = (raw - offset) / 10.0
                ParsedBalance(
                    "HK$%,.1f".format(value),
                    "Octopus formula: (raw - $offset) / 10.",
                    listOf(RawDataField("Raw Stored", raw.toString())),
                )
            }
            Edy -> {
                val balance = block.leInt(0, 4)
                ParsedBalance("¥%,d".format(balance), "Parsed from service 0x1317 as 4-byte LE.", listOf(RawDataField("Balance", balance.toString())))
            }
            Waon -> {
                val balance = (block[0].toInt() and 0xff) or ((block[1].toInt() and 0xff) shl 8)
                ParsedBalance("¥%,d".format(balance), "Parsed from service 0x6817 as 2-byte LE.", listOf(RawDataField("Balance", balance.toString())))
            }
            Nanaco -> {
                val balance = block.leInt(0, 4)
                ParsedBalance("¥%,d".format(balance), "Parsed from service 0x5597 as 4-byte LE.", listOf(RawDataField("Balance", balance.toString())))
            }
        }
    }

    fun detectedBrand(systemCodes: List<String>): String {
        if (this != JapanTransit) return displayName
        return when {
            systemCodes.any { it.equals("0003", ignoreCase = true) } -> "Japan Transit IC"
            else -> displayName
        }
    }
}

private fun ByteArray.leInt(start: Int, length: Int): Int {
    var value = 0
    for (i in 0 until length) {
        value = value or ((this[start + i].toInt() and 0xff) shl (8 * i))
    }
    return value
}

internal fun octopusOffset(scannedAt: Instant): Int =
    if(scannedAt >= Instant.parse("2017-09-30T16:00:00Z")) 500 else 350
