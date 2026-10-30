package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant

class CalypsoDecoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val tagReader = IsoDep.get(tag) ?: return null
        tagReader.use { iso ->
            iso.connect()
            iso.timeout = 2500
            val result = CalypsoProtocol.read { iso.transceive(it) } ?: return null
            if (!result.hasDecodedData) return null
            val uid = tag.id.hexString()
            val uidSerial = if (tag.id.size <= 8) {
                java.math.BigInteger(1, tag.id).toString()
            } else null
            val serial = result.serial ?: uidSerial
            return TransitCardSnapshot(
                technology = "ISO7816", cardFamily = result.family, identifierLabel = "UID", identifierValue = uid,
                rawIdentifierValue = uid, selectedAID = result.selectedAid, realSerialNumber = serial,
                balanceText = result.balanceText, balanceDetail = if (result.network == CalypsoProtocol.Network.Generic)
                    "Public Calypso records; network not identified" else "Public contracts and travel records",
                resultFields = listOfNotNull(serial?.let { ResultField("Card Number", it) }) + result.fields.map { ResultField(it.first, it.second) },
                rawSections = listOf(RawDataSection("Application", listOf(RawDataField("AID", result.selectedAid)))) + result.records.map { record ->
                    RawDataSection("Calypso SFI %02X Record %d".format(record.sfi, record.number), listOf(
                        RawDataField("Payload", record.payload.hexString()), RawDataField("SW1SW2", "9000")))
                },
                rawTransactions = result.rawHistories, rawTransitHistory = emptyList(), scannedAt = scannedAt,
            )
        }
    }
}
