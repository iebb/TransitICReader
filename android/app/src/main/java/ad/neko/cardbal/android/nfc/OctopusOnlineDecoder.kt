package ad.neko.cardbal.android.nfc

import android.content.SharedPreferences
import ad.neko.cardbal.android.BuildConfig
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.formatFeliCaId
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant
import java.util.Locale

internal class OctopusMetadataStore(private val preferences: SharedPreferences) {
    companion object {
        const val PREFERENCES = "octopus"
        const val ENABLED_KEY = "octopusOnlineEnabled"
    }
    val onlineEnabled get() = preferences.getBoolean(ENABLED_KEY, true)
    private fun key(idm: String): String? =
        idm.uppercase(Locale.ROOT).takeIf { it.matches(Regex("[0-9A-F]{16}")) }?.let { "metadata.v1.$it" }
    fun metadata(idm: String): OctopusCardMetadata? {
        val key = key(idm) ?: return null
        return runCatching {
            OctopusCardMetadata(
                preferences.getString("$key.number", null) ?: return null,
                preferences.getInt("$key.offset", 0),
                preferences.getString("$key.status", "") ?: "",
            ).takeIf { it.isValid }
        }.getOrNull()
    }
    fun save(idm: String, metadata: OctopusCardMetadata) {
        val key = key(idm) ?: return
        if (!metadata.isValid) return
        preferences.edit().putString("$key.number", metadata.cardNumber)
            .putInt("$key.offset", metadata.offset).putString("$key.status", metadata.serviceStatus).apply()
    }
}

internal object OctopusOnlineDecoder {
    fun decode(felica: FeliCaTransceiver, block: ByteArray, scannedAt: Instant, store: OctopusMetadataStore?): TransitCardSnapshot {
        val idm = felica.idm
        val identity = idm.hexString()
        val systems = felica.requestSystemCodes().ifEmpty { listOf("8008") }
        var currentBlock = block
        var metadata = store?.metadata(identity)
        var usedOnline = false
        var failed = false
        if (metadata == null && store?.onlineEnabled == true && BuildConfig.OCTOPUS_ENQUIRY_BASE_URL.isNotBlank()) {
            runCatching {
                val (result, opcodes) = OctopusEnquiryClient(BuildConfig.OCTOPUS_ENQUIRY_BASE_URL).enquire(felica::exchangeOnline)
                if (!felica.polling("8008") || !felica.idm.contentEquals(idm)) throw OctopusProtocolException()
                currentBlock = felica.readWithoutEncryption("1701", 0) ?: throw OctopusProtocolException()
                metadata = OctopusCardMetadata.calibrated(result, rawValue(currentBlock), opcodes)
                metadata?.let { store.save(identity, it); usedOnline = true } ?: run { failed = true }
            }.onFailure { failed = true }
        }
        val raw = rawValue(currentBlock)
        val confirmed = metadata
        val balance = confirmed?.let { money(raw - it.offset) }
        val detail = if (confirmed == null) "An online enquiry is needed to determine this card's balance offset."
            else if (usedOnline) "Online balance checked against the public purse."
            else "Balance decoded using this card's saved offset."
        val fields = buildList {
            add(ResultField("Card Number (IDm)", formatFeliCaId(identity)))
            if (confirmed != null) {
                add(ResultField("Octopus Number", confirmed.cardNumber))
            }
        }
        val diagnostics = buildList {
            add(RawDataField("Raw Stored", raw.toString()))
            add(RawDataField("Raw Block", currentBlock.hexString()))
            if (confirmed != null) {
                add(RawDataField("Balance Offset", confirmed.offset.toString()))
                add(RawDataField("Enquiry Status", confirmed.serviceStatus))
            } else {
                add(RawDataField("Candidate Balance (offset 350)", money(raw - 350)))
                add(RawDataField("Candidate Balance (offset 500)", money(raw - 500)))
                if (failed) add(RawDataField("Online Enquiry", "Unavailable"))
            }
        }
        val snapshot = TransitCardSnapshot(
            technology = "FeliCa", cardFamily = "Octopus", identifierLabel = "IDm",
            identifierValue = formatFeliCaId(identity), rawIdentifierValue = identity,
            systemCode = "8008", realSerialNumber = confirmed?.cardNumber,
            balanceText = balance, balanceDetail = detail, resultFields = fields,
            rawSections = listOf(
                RawDataSection("Tag", listOf(RawDataField("Technology", "FeliCa"), RawDataField("IDm", formatFeliCaId(identity)),
                    RawDataField("System Codes", systems.joinToString(", ")))),
                RawDataSection("Decoded Balance", diagnostics),
            ),
            rawTransactions = emptyList(), rawTransitHistory = emptyList(), scannedAt = scannedAt,
        )
        return snapshot.copy(applications = listOf(TransitApplication.from(snapshot)))
    }
    private fun money(tenths: Long) = "HK$%,.1f".format(Locale.getDefault(), tenths / 10.0)
    private fun rawValue(block: ByteArray): Long {
        if (block.size != 16) throw OctopusProtocolException()
        return block.take(4).fold(0L) { result, byte -> (result shl 8) or (byte.toLong() and 255) }
    }
}
