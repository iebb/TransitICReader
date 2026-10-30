package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import java.math.BigDecimal
import kotlinx.datetime.Instant

/** Implicitly selected CEPAS purse: call before readers that SELECT other apps. */
class CEPASDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val technology = IsoDep.get(tag) ?: return null
        return runCatching {
            technology.use { iso ->
                iso.connect()
                iso.timeout = 2500
                val card = CepasProtocol.read(iso::transceive) ?: return null
                TransitCardSnapshot(
                    technology = "ISO7816", cardFamily = card.family,
                    identifierLabel = "CAN", identifierValue = card.serial,
                    rawIdentifierValue = tag.id.hexString(), realSerialNumber = card.serial,
                    region = card.family,
                    balanceText = "S$${BigDecimal.valueOf(card.balanceMinor, 2).toPlainString()}",
                    balanceDetail = "On-card stored-value purse only. SimplyGo account balances are not read.",
                    resultFields = listOf(
                        ResultField("Brand", card.family), ResultField("Card Number (CAN)", card.serial),
                        ResultField("Currency", "SGD"), ResultField("Purse Status", "0x%02X".format(card.purse.status)),
                        ResultField("History", if (card.historyComplete) "On-card records read" else "Some on-card records were unavailable"),
                    ),
                    rawSections = listOf(RawDataSection("CEPAS Purse 3", listOf(RawDataField("Read Purse", card.purse.raw.hexString())))),
                    rawTransactions = card.rawHistory.map { it.hexString() }, rawTransitHistory = emptyList(),
                    scannedAt = scannedAt,
                )
            }
        }.getOrNull()
    }
}
