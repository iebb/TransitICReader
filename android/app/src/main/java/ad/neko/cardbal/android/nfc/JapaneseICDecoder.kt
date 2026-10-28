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

class JapaneseICDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = NfcF.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val nfc = NfcF.get(tag) ?: return null
        FeliCaTransceiver(nfc).use { felica ->
            felica.connect()
            for (profile in FeliCaProfile.entries) {
                if (!felica.polling(profile.systemCode)) continue
                val block = felica.readWithoutEncryption(profile.balanceService, 0) ?: continue
                val parsed = profile.parseBalance(block, scannedAt) ?: continue
                val systemCodes = felica.requestSystemCodes().ifEmpty { listOf(profile.systemCode) }
                val detected = profile.detectedBrand(systemCodes)
                val transactions = when (profile) {
                    FeliCaProfile.JapanTransit -> readService(felica, "0F09", 20)
                    FeliCaProfile.Octopus -> readService(felica, "1701", 10, start = 1)
                    FeliCaProfile.Waon -> readPairedServiceRecords(felica, "0B68", 6)
                    FeliCaProfile.Edy, FeliCaProfile.Nanaco -> readService(felica, profile.historyService ?: profile.balanceService, 20)
                }
                val transitHistory = if (profile == FeliCaProfile.JapanTransit) {
                    readService(felica, "8F10", 20) + readService(felica, "CB10", 20)
                } else {
                    emptyList()
                }
                val extraFields = if (profile == FeliCaProfile.Waon) waonExtraFields(felica) else emptyList()

                return TransitCardSnapshot(
                    technology = "FeliCa",
                    cardFamily = detected,
                    identifierLabel = if (profile == FeliCaProfile.Waon) "WAON No." else "IDm",
                    identifierValue = extraFields.firstOrNull { it.title == "WAON Number" }?.value ?: formatFeliCaId(felica.idmHex),
                    rawIdentifierValue = felica.idmHex,
                    pmm = null,
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

    private fun readService(felica: FeliCaTransceiver, service: String, limit: Int, start: Int = 0): List<String> {
        val records = mutableListOf<String>()
        for (i in start until start + limit) {
            val block = felica.readWithoutEncryption(service, i) ?: break
            if (block.size >= 2 && block[0] == 0.toByte() && block[1] == 0.toByte()) break
            records.add(block.hexString())
        }
        return records
    }

    private fun readPairedServiceRecords(felica: FeliCaTransceiver, service: String, blockLimit: Int): List<String> {
        val blocks = (0 until blockLimit).mapNotNull { index -> felica.readWithoutEncryption(service, index) }
        return blocks.chunked(2).mapNotNull { pair ->
            if (pair.size < 2) return@mapNotNull null
            val record = pair[0] + pair[1]
            if (record.all { it == 0.toByte() }) null else record.hexString()
        }
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
    Octopus("Octopus", "8008", "1701", "1701"),
    Edy("Rakuten Edy", "FE00", "1713", "0F17"),
    Waon("WAON", "FE00", "1768", "0B68"),
    Nanaco("nanaco", "FE00", "9755", "4F56");

    fun parseBalance(block: ByteArray, scannedAt: Instant): ParsedBalance? {
        if (block.size < 16) return null
        return when (this) {
            JapanTransit -> {
                val balance = (block[11].toInt() and 0xff) or ((block[12].toInt() and 0xff) shl 8)
                ParsedBalance(
                    "¥%,d".format(balance),
                    "Parsed from bytes 11-12 in little-endian order.",
                    listOf(RawDataField("Balance", balance.toString()), RawDataField("Bytes 11-12", "%02X%02X".format(block[11], block[12]))),
                )
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

private fun octopusOffset(scannedAt: Instant): Int {
    val date = scannedAt.toLocalDateTime(TimeZone.currentSystemDefault()).date
    return if (
        date.year > 2010 ||
        (date.year == 2010 && date.monthNumber > 12) ||
        (date.year == 2010 && date.monthNumber == 12 && date.dayOfMonth >= 1)
    ) {
        350
    } else {
        35
    }
}
