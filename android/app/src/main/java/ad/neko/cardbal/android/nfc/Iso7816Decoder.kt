package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant
import java.math.BigDecimal

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
                val balanceResponse = runCatching { iso.transceive(Iso7816Protocol.balanceCommand(selection.application)) }.getOrNull()
                val snapperCandidate = aid == SnapperPlusProtocol.APPLICATION_AID &&
                    SnapperPlusProtocol.purseIssuer(select.dropLast(2).toByteArray()) == 2
                // Never turn a failed candidate purse read into a KRW balance.
                if (snapperCandidate && (balanceResponse == null || SnapperPlusProtocol.balanceMinor(balanceResponse) == null)) return null
                val snapper = if (snapperCandidate) SnapperPlusProtocol.read(aid, select, balanceResponse!!) { iso.transceive(it) } else null
                val resolvedFamily = if (snapper != null) "Snapper+" else family
                val balance = if (snapper != null) {
                    "NZ$${BigDecimal.valueOf(snapper.balanceMinor, 2).toPlainString()}" to "Snapper+ purse balance (NZD cents)"
                } else readBalance(balanceResponse, selection.application)
                val transactions = if (family == "China T-Union") {
                    readRecords(iso, sfi = 0x18, maxRecords = 10, minimumPayloadBytes = 23)
                } else if (snapper != null) {
                    snapper.history.map { it.hexString() }
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
                    cardFamily = resolvedFamily,
                    identifierLabel = "UID",
                    identifierValue = uid.chunked(4).joinToString(" "),
                    rawIdentifierValue = uid,
                    selectedAID = aid,
                    balanceText = balance?.first,
                    balanceDetail = balance?.second,
                    realSerialNumber = if (snapper != null) SnapperPlusProtocol.purseSerial(select.dropLast(2).toByteArray()) else null,
                    resultFields = listOf(ResultField("Selected AID", aid), ResultField("Brand", resolvedFamily)),
                    rawSections = listOfNotNull(
                        RawDataSection("Application", listOf(RawDataField("AID", aid), RawDataField("Select Response", select.hexString()))),
                        selection.configurationResponse?.let {
                            RawDataSection("KROCAP Configuration", listOf(
                                RawDataField("AID", Iso7816Protocol.CONFIGURATION_AID),
                                RawDataField("Select Response", it.hexString()),
                            ))
                        },
                        snapper?.let {
                            RawDataSection("Snapper+ SFI Records",
                                it.transactions.map { (number, payload) -> RawDataField("SFI 04 Record $number", payload.hexString()) } +
                                    it.trips.map { (number, payload) -> RawDataField("SFI 03 Record $number", payload.hexString()) })
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

    private fun readBalance(response: ByteArray?, application: Iso7816Protocol.Application): Pair<String, String>? {
        if (response == null) return null
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
