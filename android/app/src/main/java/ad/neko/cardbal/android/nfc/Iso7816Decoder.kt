package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant

class Iso7816Decoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val isoDep = IsoDep.get(tag) ?: return null
        isoDep.use { iso ->
            iso.connect()
            iso.timeout = 2500
            for (candidateAid in Iso7816Protocol.selectionAids) {
                val selection = Iso7816Protocol.select(candidateAid) { iso.transceive(it) } ?: continue
                val (aid, family) = selection.application
                val select = selection.response
                val balance = readBalance(iso, selection.application)
                val transactions = if (family == "China T-Union") {
                    readRecords(iso, sfi = 0x18, maxRecords = 10, minimumPayloadBytes = 23)
                } else {
                    readRecords(iso, sfi = 4, maxRecords = 20)
                }
                val transitHistory = if (family == "China T-Union") {
                    readRecords(iso, sfi = 0x1E, maxRecords = 30, minimumPayloadBytes = 48)
                } else {
                    emptyList()
                }
                val uid = tag.id.hexString()
                return TransitCardSnapshot(
                    technology = "ISO7816",
                    cardFamily = family,
                    identifierLabel = "UID",
                    identifierValue = uid.chunked(4).joinToString(" "),
                    rawIdentifierValue = uid,
                    selectedAID = aid,
                    balanceText = balance?.first,
                    balanceDetail = balance?.second,
                    resultFields = listOf(ResultField("Selected AID", aid), ResultField("Brand", family)),
                    rawSections = listOfNotNull(
                        RawDataSection("Application", listOf(RawDataField("AID", aid), RawDataField("Select Response", select.hexString()))),
                        selection.configurationResponse?.let {
                            RawDataSection("KROCAP Configuration", listOf(
                                RawDataField("AID", Iso7816Protocol.CONFIGURATION_AID),
                                RawDataField("Select Response", it.hexString()),
                            ))
                        },
                    ),
                    rawTransactions = transactions,
                    rawTransitHistory = transitHistory,
                    scannedAt = scannedAt,
                )
            }
        }
        return null
    }

    private fun readBalance(iso: IsoDep, application: Iso7816Protocol.Application): Pair<String, String>? {
        val response = runCatching { iso.transceive(Iso7816Protocol.balanceCommand(application)) }
            .getOrNull() ?: return null
        val amount = Iso7816Protocol.balanceValue(response) ?: return null
        return if (application.currency == "KRW") {
            "₩%,d".format(amount) to "KS X 6924 purse balance"
        } else {
            "¥%,.2f".format(amount / 100.0) to "PBOC/T-Union balance"
        }
    }

    private fun readRecords(iso: IsoDep, sfi: Int, maxRecords: Int, minimumPayloadBytes: Int = 1): List<String> {
        val records = mutableListOf<String>()
        for (record in 1..maxRecords) {
            val p2 = ((sfi shl 3) or 4).toByte()
            val command = byteArrayOf(0x00, 0xB2.toByte(), record.toByte(), p2, 0x00)
            var response = runCatching { iso.transceive(command) }.getOrNull() ?: break
            if (response.isLeRetry) {
                val retryLe = response.last().takeIf { it != 0.toByte() } ?: 0x00
                response = runCatching {
                    iso.transceive(byteArrayOf(0x00, 0xB2.toByte(), record.toByte(), p2, retryLe))
                }.getOrNull() ?: break
            }
            if (!response.isSuccess) break
            val payload = response.dropLast(2).toByteArray()
            if (payload.isEmpty() || payload.all { it == 0.toByte() }) break
            if (payload.size < minimumPayloadBytes) continue
            records.add(payload.hexString())
        }
        return records
    }
}

private val ByteArray.isLeRetry: Boolean
    get() = size >= 2 && this[size - 2] == 0x6C.toByte()
