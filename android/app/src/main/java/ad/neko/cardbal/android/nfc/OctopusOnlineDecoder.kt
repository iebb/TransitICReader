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
        const val CARD_UPDATES_KEY = "octopusCardUpdatesEnabled"
    }
    val onlineEnabled get() = preferences.getBoolean(ENABLED_KEY, true)
    /** Card updates are writes the service asks the card to make. They stay off until the person opts in. */
    val cardUpdatesAllowed get() = preferences.getBoolean(CARD_UPDATES_KEY, false)
    private fun key(idm: String): String? =
        idm.uppercase(Locale.ROOT).takeIf { it.matches(Regex("[0-9A-F]{16}")) }?.let { "metadata.v1.$it" }
    fun metadata(idm: String): OctopusCardMetadata? {
        val key = key(idm) ?: return null
        return runCatching {
            OctopusCardMetadata(
                preferences.getString("$key.number", null) ?: return null,
                preferences.getInt("$key.offset", 0),
                preferences.getString("$key.status", "") ?: "",
                exchangeRate = preferences.getString("$key.rate", null)?.takeIf(OctopusExchangeRate::isValidRate)?.let { rate ->
                    val validUntil = preferences.getString("$key.rateValidUntil", null)?.takeIf { it.isNotEmpty() }
                    OctopusExchangeRate(rate, validUntil?.let { runCatching { Instant.parse(it) }.getOrNull() })
                },
                rateChecked = preferences.getBoolean("$key.rateChecked", false),
            ).takeIf { it.isValid }
        }.getOrNull()
    }
    fun save(idm: String, metadata: OctopusCardMetadata) {
        val key = key(idm) ?: return
        if (!metadata.isValid) return
        // An empty rate clears one saved by an earlier enquiry.
        preferences.edit().putString("$key.number", metadata.cardNumber)
            .putInt("$key.offset", metadata.offset).putString("$key.status", metadata.serviceStatus)
            .putString("$key.rate", metadata.exchangeRate?.rate ?: "")
            .putString("$key.rateValidUntil", metadata.exchangeRate?.validUntil?.toString() ?: "")
            .putBoolean("$key.rateChecked", metadata.rateChecked).apply()
    }
}

internal object OctopusOnlineDecoder {
    /** Builds without an enquiry endpoint do not offer Octopus Online at all. */
    val isAvailable get() = BuildConfig.OCTOPUS_ENQUIRY_BASE_URL.isNotBlank()

    fun decode(felica: FeliCaTransceiver, block: ByteArray, scannedAt: Instant, store: OctopusMetadataStore?): TransitCardSnapshot =
        decode(felica.protocol, block, scannedAt, store, if (isAvailable) OctopusEnquiryClient(BuildConfig.OCTOPUS_ENQUIRY_BASE_URL) else null)

    /** [client] is null in builds without an enquiry endpoint. */
    internal fun decode(
        felica: FeliCaProtocol, block: ByteArray, scannedAt: Instant, store: OctopusMetadataStore?, client: OctopusEnquiryClient?,
    ): TransitCardSnapshot {
        val idm = felica.idm
        val identity = idm.hexString()
        val systems = felica.requestSystemCodes().ifEmpty { listOf("8008") }
        var currentBlock = block
        val saved = store?.metadata(identity)
        var metadata = saved
        var usedOnline = false
        var failed = false
        var skippedCardUpdates = 0
        // A top-up changes the exchange rate of an Octopus – China T-Union card, so such a card
        // asks again on every scan and keeps its saved details when that fails. Details saved
        // before the app read rates are checked once more to find out whether the card has one.
        val refreshesRate = saved != null && (saved.exchangeRate != null || !saved.rateChecked)
        if ((saved == null || refreshesRate) && store?.onlineEnabled == true && client != null) {
            runCatching {
                val (result, opcodes) = client.enquire(store.cardUpdatesAllowed, felica::exchangeOnline)
                // Only a card update can change the purse; after reads alone the purse read before the enquiry still holds.
                if (OctopusEnquiryVm.mayHaveUpdatedCard(opcodes)) {
                    if (!felica.polling("8008") || !felica.idm.contentEquals(idm)) throw OctopusProtocolException()
                    currentBlock = felica.readWithoutEncryption("1701", 0) ?: throw OctopusProtocolException()
                }
                val calibrated = OctopusCardMetadata.calibrated(result, rawValue(currentBlock), opcodes)
                if (calibrated != null) {
                    store.save(identity, calibrated)
                    metadata = calibrated
                    usedOnline = true
                } else {
                    failed = true
                }
            }.onFailure { failed = true }
            skippedCardUpdates = client.skippedCardUpdates
        }
        val raw = rawValue(currentBlock)
        val confirmed = metadata
        val balance = confirmed?.let { money(raw - it.offset) }
        val detail = if (confirmed == null) "An online enquiry is needed to determine this card's balance offset.".takeIf { isAvailable }
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
            if (skippedCardUpdates > 0) add(RawDataField("Skipped Card Updates", skippedCardUpdates.toString()))
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
            exchangeRate = confirmed?.exchangeRate,
        )
        return snapshot.copy(applications = listOf(TransitApplication.from(snapshot)))
    }
    private fun money(tenths: Long) = "HK$%,.1f".format(Locale.getDefault(), tenths / 10.0)
    private fun rawValue(block: ByteArray): Long {
        if (block.size != 16) throw OctopusProtocolException()
        return block.take(4).fold(0L) { result, byte -> (result shl 8) or (byte.toLong() and 255) }
    }
}
