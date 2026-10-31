package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.OctopusExchangeRate
import kotlinx.datetime.Instant
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.text.DecimalFormat
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
import kotlin.time.Duration.Companion.seconds

@Serializable
data class TransitApplicationRecord(val kind: String, val sfi: Int, val index: Int, val hex: String) {
    val identity get() = "$kind:$sfi:${hex.uppercase()}"
}

/** Persist application/file identity exactly as in the portable iPhone backup. */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class TransitApplication(
    val technology: String, val cardFamily: String, val identifier: String,
    val selectedAID: String? = null, val systemCode: String? = null,
    val serialNumber: String? = null, val cityCode: String? = null, val region: String? = null,
    val balanceText: String? = null, val balanceDetail: String? = null,
    @Serializable(with = FlexibleInstantSerializer::class) val balanceReadAt: Instant? = null,
    val fields: List<SavedCardField> = emptyList(), val diagnostics: List<DiagnosticSection> = emptyList(),
    val records: List<TransitApplicationRecord> = emptyList(),
    @Serializable(with = FlexibleInstantSerializer::class) val scannedAt: Instant,
    /** Octopus side of an Octopus – China T-Union card: the rate the service last reported.
     *  Left out of saved data when absent, so other cards are stored as before. */
    @EncodeDefault(EncodeDefault.Mode.NEVER) val exchangeRate: OctopusExchangeRate? = null,
) {
    @Serializable data class DiagnosticSection(val title: String, val fields: List<SavedCardField>)
    val id get() = "$technology:${selectedAID ?: systemCode ?: cardFamily}"
    val isCityUnion get() = selectedAID == "A00000000386980701"
    val isTUnion get() = selectedAID == "A000000632010105"
    val isOctopus get() = technology == "FeliCa" && systemCode == "8008"
    val isMacauPass get() = selectedAID == "B0C4C3C5CDA8C7AEB0FC"
    companion object {
        fun from(snapshot: TransitCardSnapshot, records: List<TransitApplicationRecord>? = null, city: String? = null) = TransitApplication(
            technology=snapshot.technology,cardFamily=snapshot.cardFamily,identifier=snapshot.rawIdentifierValue,
            selectedAID=snapshot.selectedAID,systemCode=snapshot.systemCode,serialNumber=snapshot.realSerialNumber,cityCode=city,
            region=snapshot.region,balanceText=snapshot.balanceText,balanceDetail=snapshot.balanceDetail,
            balanceReadAt=snapshot.scannedAt.takeIf { snapshot.balanceText != null },fields=snapshot.resultFields.map { SavedCardField(it.title,it.value) },
            diagnostics=snapshot.rawSections.map { DiagnosticSection(it.title,it.fields.map { f -> SavedCardField(f.title,f.value) }) },
            records=records ?: (snapshot.rawTransactions.mapIndexed { i,raw -> TransitApplicationRecord("transaction",if(snapshot.technology=="ISO7816") 0x18 else 0,i+1,raw) } + snapshot.rawTransitHistory.mapIndexed { i,raw -> TransitApplicationRecord("transit",if(snapshot.technology=="ISO7816") 0x1e else 0,i+1,raw) }),
            scannedAt=snapshot.scannedAt,exchangeRate=snapshot.exchangeRate,
        )
        fun fromSaved(card: SavedCardRecord): TransitApplication = from(TransitCardSnapshot(
            technology=card.technology,cardFamily=card.cardFamily,identifierLabel=card.identifierLabel,
            identifierValue=card.identifierValue,rawIdentifierValue=card.rawIdentifierValue,selectedAID=card.selectedAID,systemCode=card.systemCode,
            realSerialNumber=card.realSerialNumber,region=card.region,balanceText=card.balanceText,balanceDetail=card.balanceDetail,
            resultFields=card.resultFields.map{ResultField(it.title,it.value)},rawTransactions=card.rawTransactions,rawTransitHistory=card.rawTransitHistory,scannedAt=card.scannedAt))
        fun merge(existing: List<TransitApplication>, incoming: List<TransitApplication>): List<TransitApplication> {
            val result=existing.toMutableList()
            for (app in incoming) {
                val index=result.indexOfFirst { it.id==app.id }
                if(index<0) { result.add(app);continue }
                val old=result[index];val latest=if(app.scannedAt>=old.scannedAt) app else old;val other=if(latest===app) old else app
                // An imported backup has no UID; keep the one a scan read.
                result[index]=latest.copy(identifier=latest.identifier.ifEmpty { other.identifier },
                    serialNumber=latest.serialNumber ?: other.serialNumber,cityCode=latest.cityCode ?: other.cityCode,
                    balanceText=latest.balanceText ?: other.balanceText,balanceDetail=if(latest.balanceText==null) other.balanceDetail else latest.balanceDetail,
                    balanceReadAt=if(latest.balanceText==null) other.balanceReadAt else latest.balanceReadAt,
                    exchangeRate=latest.exchangeRate ?: other.exchangeRate,
                    fields=(latest.fields+other.fields).distinctBy { it.title },records=(latest.records+other.records).distinctBy { it.identity })
            }
            return result
        }
        fun combine(snapshots: List<TransitCardSnapshot>): TransitCardSnapshot? {
            if(snapshots.isEmpty()) return null
            if(snapshots.size==1) return snapshots.first()
            val apps=snapshots.flatMap { it.applications ?: listOf(from(it)) }
            val primary=primary(apps)!!
            val base=snapshots.first { snapshot -> (snapshot.applications ?: listOf(from(snapshot))).any { it.id==primary.id } }
            return base.copy(technology=if(apps.map{it.technology}.distinct().size>1) "Dual Mode" else base.technology,
                cardFamily=family(apps),balanceText=balanceSource(apps)?.balanceText,balanceDetail=balanceDetail(apps),
                selectedAID=primary.selectedAID,realSerialNumber=primary.serialNumber,
                rawTransactions=apps.flatMap { it.records.filter { r -> r.kind=="transaction" }.map { r -> r.hex } },
                rawTransitHistory=apps.flatMap { it.records.filter { r -> r.kind=="transit" }.map { r -> r.hex } }, applications=apps,
                exchangeRate=apps.firstOrNull { it.isOctopus }?.exchangeRate)
        }
        fun primary(apps: List<TransitApplication>) = apps.firstOrNull { it.isOctopus } ?: apps.firstOrNull { it.isMacauPass } ?: apps.firstOrNull { it.isTUnion } ?: apps.firstOrNull()
        fun family(apps: List<TransitApplication>) = if(apps.any{it.isOctopus} && apps.any{it.isTUnion || it.isCityUnion}) "Octopus + ${apps.first{it.isTUnion || it.isCityUnion}.cardFamily}" else primary(apps)?.cardFamily.orEmpty()
        fun balanceSource(apps: List<TransitApplication>) = apps.firstOrNull { it.isOctopus }
            ?: apps.firstOrNull { it.isMacauPass }
            ?: apps.filter { it.balanceText != null }.maxWithOrNull(
                compareBy<TransitApplication> { it.balanceReadAt ?: it.scannedAt }.thenBy { it.isTUnion })
        fun balanceDetail(apps: List<TransitApplication>) = apps.mapNotNull { a -> a.balanceText?.let { "${a.cardFamily}: $it" } }.joinToString("\n")
    }
}

/** What an Octopus – China T-Union card shows beside its HKD balance. It exists only when the
 *  Octopus service reported a rate for the card; every other card keeps its single balance. */
data class DualCurrencyBalance(
    /** "CN¥12.30" from the T-Union side, or null when that side was not read with the HKD balance. */
    val yuanBalance: String?,
    val exchangeRate: OctopusExchangeRate,
) {
    /** "HK$1 = CN¥0.839" */
    val rateText: String get() = "HK\$1 = CN¥" + exchangeRate.rate

    companion object {
        /** Both sides spend one purse, so a yuan balance read further apart than this is out of date. */
        val SAME_SCAN_WINDOW = 120.seconds

        fun from(applications: List<TransitApplication>?, locale: Locale = Locale.getDefault()): DualCurrencyBalance? {
            val apps = applications ?: return null
            val octopus = apps.firstOrNull { it.isOctopus && it.exchangeRate != null } ?: return null
            val rate = octopus.exchangeRate ?: return null
            val mainland = apps.firstOrNull { it.isTUnion } ?: apps.firstOrNull { it.isCityUnion }
            val yuan = mainland?.let { app ->
                val text = app.balanceText ?: return@let null
                val octopusRead = octopus.balanceReadAt ?: return@let null
                if (((app.balanceReadAt ?: app.scannedAt) - octopusRead).absoluteValue > SAME_SCAN_WINDOW) return@let null
                yuanText(text, locale)
            }
            return DualCurrencyBalance(yuan, rate)
        }

        /** Re-labels a stored CNY balance as "CN¥": a bare "¥" reads as yen in Japanese. */
        fun yuanText(balanceText: String, locale: Locale = Locale.getDefault()): String? {
            val whole = StringBuilder()
            var fraction: StringBuilder? = null
            for (character in balanceText) {
                val digit = character.digitToIntOrNull()
                if (digit != null) {
                    (fraction ?: whole).append(digit)
                } else if (character in ".,\u066B\u066C" && whole.isNotEmpty()) {
                    // A separator before the last one was grouping.
                    fraction?.let(whole::append)
                    fraction = StringBuilder()
                }
            }
            fraction?.let { if (it.length != 2) { whole.append(it); fraction = null } }
            if (whole.isEmpty()) return null
            val units = BigDecimal(whole.toString() + (fraction?.let { ".$it" } ?: ""))
            val negative = '-' in balanceText || '\u2212' in balanceText
            val amount = if (negative) units.negate() else units
            val format = NumberFormat.getCurrencyInstance(locale)
            if (format !is DecimalFormat) return "CN¥" + NumberFormat.getNumberInstance(locale).apply {
                minimumFractionDigits = 2; maximumFractionDigits = 2
            }.format(amount)
            format.currency = Currency.getInstance("CNY")
            format.decimalFormatSymbols = format.decimalFormatSymbols.apply { currencySymbol = "CN¥" }
            format.minimumFractionDigits = 2
            format.maximumFractionDigits = 2
            return format.format(amount)
        }
    }
}

/** Recompute a saved card's summary from its merged applications, as a combined scan does. */
fun SavedCardRecord.withApplications(apps: List<TransitApplication>): SavedCardRecord {
    val primary=TransitApplication.primary(apps) ?: return this
    return copy(applications=apps,technology=if(apps.map{it.technology}.distinct().size>1) "Dual Mode" else primary.technology,
        cardFamily=TransitApplication.family(apps),selectedAID=primary.selectedAID,realSerialNumber=primary.serialNumber ?: realSerialNumber,
        balanceText=TransitApplication.balanceSource(apps)?.balanceText ?: balanceText,balanceDetail=TransitApplication.balanceDetail(apps).ifEmpty { balanceDetail },
        rawTransactions=apps.flatMap { it.records.filter { r -> r.kind=="transaction" }.map { r -> r.hex } },
        rawTransitHistory=apps.flatMap { it.records.filter { r -> r.kind=="transit" }.map { r -> r.hex } })
}
