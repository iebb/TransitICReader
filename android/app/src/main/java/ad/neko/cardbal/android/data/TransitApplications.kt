package ad.neko.cardbal.android.data

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class TransitApplicationRecord(val kind: String, val sfi: Int, val index: Int, val hex: String) {
    val identity get() = "$kind:$sfi:${hex.uppercase()}"
}

/** Persist application/file identity exactly as in the portable iPhone backup. */
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
) {
    @Serializable data class DiagnosticSection(val title: String, val fields: List<SavedCardField>)
    val id get() = "$technology:${selectedAID ?: systemCode ?: cardFamily}"
    val isCityUnion get() = selectedAID == "A00000000386980701"
    val isTUnion get() = selectedAID == "A000000632010105"
    val isOctopus get() = technology == "FeliCa" && systemCode == "8008"
    companion object {
        fun from(snapshot: TransitCardSnapshot, records: List<TransitApplicationRecord>? = null, city: String? = null) = TransitApplication(
            technology=snapshot.technology,cardFamily=snapshot.cardFamily,identifier=snapshot.rawIdentifierValue,
            selectedAID=snapshot.selectedAID,systemCode=snapshot.systemCode,serialNumber=snapshot.realSerialNumber,cityCode=city,
            region=snapshot.region,balanceText=snapshot.balanceText,balanceDetail=snapshot.balanceDetail,
            balanceReadAt=snapshot.scannedAt.takeIf { snapshot.balanceText != null },fields=snapshot.resultFields.map { SavedCardField(it.title,it.value) },
            diagnostics=snapshot.rawSections.map { DiagnosticSection(it.title,it.fields.map { f -> SavedCardField(f.title,f.value) }) },
            records=records ?: (snapshot.rawTransactions.mapIndexed { i,raw -> TransitApplicationRecord("transaction",if(snapshot.technology=="ISO7816") 0x18 else 0,i+1,raw) } + snapshot.rawTransitHistory.mapIndexed { i,raw -> TransitApplicationRecord("transit",if(snapshot.technology=="ISO7816") 0x1e else 0,i+1,raw) }),
            scannedAt=snapshot.scannedAt,
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
                result[index]=latest.copy(serialNumber=latest.serialNumber ?: other.serialNumber,cityCode=latest.cityCode ?: other.cityCode,
                    balanceText=latest.balanceText ?: other.balanceText,balanceDetail=if(latest.balanceText==null) other.balanceDetail else latest.balanceDetail,
                    balanceReadAt=if(latest.balanceText==null) other.balanceReadAt else latest.balanceReadAt,
                    fields=(latest.fields+other.fields).distinctBy { it.title },records=(latest.records+other.records).distinctBy { it.identity })
            }
            return result
        }
        fun combine(snapshots: List<TransitCardSnapshot>): TransitCardSnapshot? {
            if(snapshots.isEmpty()) return null
            if(snapshots.size==1) return snapshots.first()
            val apps=snapshots.flatMap { it.applications ?: listOf(from(it)) }
            val primary=apps.firstOrNull { it.isOctopus } ?: apps.firstOrNull { it.isTUnion } ?: apps.first()
            val base=snapshots.first { snapshot -> (snapshot.applications ?: listOf(from(snapshot))).any { it.id==primary.id } }
            val balance=apps.firstOrNull { it.isOctopus } ?: apps.filter { it.balanceText!=null }.maxByOrNull { it.balanceReadAt ?: it.scannedAt }
            return base.copy(technology=if(apps.map{it.technology}.distinct().size>1) "Dual Mode" else base.technology,
                cardFamily=if(apps.any{it.isOctopus} && apps.any{it.isTUnion || it.isCityUnion}) "Octopus + ${apps.first{it.isTUnion || it.isCityUnion}.cardFamily}" else primary.cardFamily,
                balanceText=balance?.balanceText,balanceDetail=apps.mapNotNull { a -> a.balanceText?.let { "${a.cardFamily}: $it" } }.joinToString("\n"),
                selectedAID=primary.selectedAID,realSerialNumber=primary.serialNumber,
                rawTransactions=apps.flatMap { it.records.filter { r -> r.kind=="transaction" }.map { r -> r.hex } },
                rawTransitHistory=apps.flatMap { it.records.filter { r -> r.kind=="transit" }.map { r -> r.hex } }, applications=apps)
        }
    }
}
