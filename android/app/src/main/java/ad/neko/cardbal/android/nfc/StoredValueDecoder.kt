package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import java.math.BigDecimal
import java.time.Instant as JavaInstant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.datetime.Instant

/** Read-only callback adapter; matching a chip or AID alone never yields a card. */
class StoredValueDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val connection = IsoDep.get(tag) ?: return null
        val card = try {
            connection.connect()
            connection.timeout = 2000
            StoredValueProtocol.readFirst(DesfireReadSession.WireMode.WRAPPED, connection::transceive)
        } finally {
            runCatching { connection.close() }
        } ?: return null
        val fields = mutableListOf(ResultField("Detected Type", card.family))
        card.serial?.let { fields.add(ResultField("Card Number", it)) }
        card.passes.forEachIndexed { index, pass ->
            fields.add(ResultField("${pass.label} ${index + 1}", "Product ${pass.productCode}, zone ${pass.zoneCode}"))
            val formatter = DateTimeFormatter.ofPattern(if (pass.label == "Season pass") "yyyy-MM-dd" else "yyyy-MM-dd HH:mm")
                .withZone(ZoneId.of("Europe/Helsinki"))
            pass.validFromEpochSeconds?.let { fields.add(ResultField("Pass ${index + 1} Valid From", formatter.format(JavaInstant.ofEpochSecond(it)))) }
            pass.validToEpochSeconds?.let { fields.add(ResultField("Pass ${index + 1} Valid To", formatter.format(JavaInstant.ofEpochSecond(it)))) }
        }
        return TransitCardSnapshot(
            technology = "DESFire", cardFamily = card.family, identifierLabel = "UID",
            identifierValue = tag.id.hexString(), rawIdentifierValue = tag.id.hexString(),
            balanceText = card.balanceMinor?.let { "${card.currencyCode} ${BigDecimal.valueOf(it, 2).toPlainString()}" },
            balanceDetail = card.metadata["scope"], realSerialNumber = card.serial,
            resultFields = fields,
            rawSections = listOf(RawDataSection("DESFire", card.metadata.toSortedMap().map { RawDataField(it.key, it.value) })),
            rawTransactions = card.rawTransactions, rawTransitHistory = emptyList(), scannedAt = scannedAt,
        )
    }
}
