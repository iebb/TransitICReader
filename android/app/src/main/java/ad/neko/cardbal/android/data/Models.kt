package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.SnapperPlusProtocol
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.roundToLong

@Serializable
data class SavedCardField(
    val title: String,
    val value: String,
    val id: String = "$title|$value",
)

@Serializable
data class SavedCardColor(
    val red: Double,
    val green: Double,
    val blue: Double,
) {
    companion object {
        val Black = SavedCardColor(0.0, 0.0, 0.0)
        val White = SavedCardColor(1.0, 1.0, 1.0)
        fun defaultFor(family: String): SavedCardColor {
            val f = family.lowercase()
            return when {
                f == "clipper" || f == "clipper ticket" -> SavedCardColor(0.15, 0.29, 0.53)
                f == "macau pass" -> SavedCardColor(0.0, 0.48, 0.27)
                f == "snapper+" || f == "snapper plus" -> SavedCardColor(0.76, 0.08, 0.17)
                f == "kmt" || f == "kartu multi trip" -> SavedCardColor(0.16, 0.47, 0.31)
                "suica" in f -> SavedCardColor(0.10, 0.58, 0.12)
                "pasmo" in f -> SavedCardColor(0.88, 0.28, 0.44)
                "icoca" in f -> SavedCardColor(0.00, 0.48, 0.72)
                "hayakaken" in f -> SavedCardColor(0.00, 0.68, 0.94)
                "sugoca" in f -> SavedCardColor(0.82, 0.10, 0.12)
                "manaca" in f -> SavedCardColor(0.96, 0.53, 0.14)
                "t-money" in f || "ezl" in f -> SavedCardColor(0.94, 0.50, 0.00)
                "octopus" in f -> SavedCardColor(0.92, 0.48, 0.10)
                "china" in f || "union" in f -> SavedCardColor(0.75, 0.10, 0.12)
                else -> SavedCardColor(0.19, 0.38, 0.73)
            }
        }
    }
}

@Serializable
enum class SavedCardDesign { classic, sunrise }

@Serializable
enum class ImageFaceEnhancer { mask, border, none }

@Serializable
enum class SavedCardMarkerShape { circle, square }

enum class RawHistoryKind { Transactions, Transit }

object FlexibleInstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("FlexibleInstant", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeString(value.toString())
    }

    override fun deserialize(decoder: Decoder): Instant {
        if (decoder is JsonDecoder) {
            val primitive = decoder.decodeJsonElement().jsonPrimitive
            if (primitive.isString) return Instant.parse(primitive.content)
            primitive.doubleOrNull?.let { appleReferenceSeconds ->
                val unixSeconds = appleReferenceSeconds + 978_307_200.0
                return Instant.fromEpochMilliseconds((unixSeconds * 1000.0).roundToLong())
            }
        }
        return Instant.parse(decoder.decodeString())
    }
}

@Serializable
enum class TransactionCategory {
    topUp, tapOn, tapOff, payment, purchase, adjustment, refund, bus, busOn, busOff,
    train, trainOn, trainOff, ferry, unknown
}

@Serializable
data class TransitTransaction(
    val date: Instant? = null,
    val time: String? = null,
    val amount: Long = 0,
    val terminalID: String? = null,
    val recordNumber: Int? = null,
    val type: String,
    val category: TransactionCategory = TransactionCategory.unknown,
    val balanceAfter: Long? = null,
    val location: String? = null,
    val entryStation: String? = null,
    val exitStation: String? = null,
    val entryStationCode: String? = null,
    val exitStationCode: String? = null,
    val rawData: String? = null,
    val sourceApplicationID: String? = null,
    val currencyCode: String? = null,
    val fractionDigits: Int = 0,
    val issuerTimeZone: String? = null,
    val amountIsSigned: Boolean = false,
    val amountKnown: Boolean = true,
    val recordCounter: Long? = null,
)

data class RawRecordValue(
    val title: String,
    val value: String,
    val source: String,
    val byteRange: IntRange? = null,
    val bitRange: IntRange? = null,
)

data class RawRecordExplanation(
    val title: String,
    val summary: String,
    val values: List<RawRecordValue>,
)

data class StationRoute(
    val id: String,
    val title: String,
    val points: List<StationPoint>,
    val rawData: String? = null,
)

data class ResultField(val title: String, val value: String)
data class RawDataField(val title: String, val value: String)
data class RawDataSection(val title: String, val fields: List<RawDataField>)

data class TransitCardSnapshot(
    val technology: String,
    val cardFamily: String,
    val identifierLabel: String,
    val identifierValue: String,
    val rawIdentifierValue: String,
    val pmm: String? = null,
    val systemCode: String? = null,
    val selectedAID: String? = null,
    val balanceText: String? = null,
    val balanceDetail: String? = null,
    val realSerialNumber: String? = null,
    val region: String? = null,
    val resultFields: List<ResultField> = emptyList(),
    val rawSections: List<RawDataSection> = emptyList(),
    val rawTransactions: List<String> = emptyList(),
    val rawTransitHistory: List<String> = emptyList(),
    val applications: List<TransitApplication>? = null,
    val scannedAt: Instant = Clock.System.now(),
) {
    val storageIdentifier: String get() {
        if (cardFamily == "Clipper" && selectedAID == "9011F2" && rawIdentifierValue.isNotEmpty()) {
            return "DESFire|$rawIdentifierValue"
        }
        val primary=applications?.let { TransitApplication.primary(it) }
        if(primary!=null) return "${primary.technology}|${primary.serialNumber?.takeIf{it.isNotBlank()} ?: primary.identifier}"
        val serial=realSerialNumber?.trim()?.takeIf{it.isNotEmpty() && it.any{c->c!='0' && c!=' ' && c!='F' && c!='f'}}
        if(technology=="ISO7816" && serial!=null) {
            val normalized=if(cardFamily.equals("Snapper+",true) || cardFamily.equals("Snapper Plus",true)) SnapperPlusProtocol.normalizedSerial(serial) else serial
            if(normalized!=null) return "$technology|$normalized"
        }
        return "$technology|$rawIdentifierValue"
    }
}

@Serializable
data class SavedCardRecord(
    val id: String,
    val cardFamily: String,
    val markerSymbolName: String? = null,
    val markerColor: SavedCardColor = SavedCardColor.Black,
    val markerOuterColor: SavedCardColor = SavedCardColor.White,
    val markerShape: SavedCardMarkerShape = SavedCardMarkerShape.circle,
    val customTitle: String? = null,
    val customDisplaySerialNumber: String? = null,
    val isUsingImage: Boolean? = null,
    val hideTitleOnImage: Boolean? = null,
    val hideSerialNumber: Boolean? = null,
    val imageFaceEnhancer: ImageFaceEnhancer = ImageFaceEnhancer.mask,
    val autoImageTextColors: Boolean = true,
    val autoTitleTextColor: SavedCardColor? = null,
    val autoBalanceTextColor: SavedCardColor? = null,
    val titleTextColorOverride: SavedCardColor? = null,
    val balanceTextColorOverride: SavedCardColor? = null,
    val technology: String,
    val identifierLabel: String,
    val rawIdentifierValue: String,
    val identifierValue: String,
    val pmm: String? = null,
    val selectedAID: String? = null,
    val systemCode: String? = null,
    val balanceText: String? = null,
    val balanceDetail: String? = null,
    val realSerialNumber: String? = null,
    val region: String? = null,
    val applications: List<TransitApplication>? = null,
    val enhancedFeliCaDecoded: Boolean? = null,
    val issuingCity: String? = null,
    val cardTypeStr: String? = null,
    val issueDateStr: String? = null,
    val expiryDateStr: String? = null,
    val rawTransactions: List<String> = emptyList(),
    val rawTransitHistory: List<String> = emptyList(),
    val resultFields: List<SavedCardField> = emptyList(),
    @Serializable(with = FlexibleInstantSerializer::class)
    val scannedAt: Instant,
    val color: SavedCardColor,
    val design: SavedCardDesign = SavedCardDesign.classic,
    val faceImageFileName: String? = null,
    val order: Int = 0,
    val isPinned: Boolean? = null,
) {
    val displayTitle: String
        get() {
            val custom = customTitle?.trim().orEmpty()
            if (custom.isNotEmpty()) return custom
            if ("union" in cardFamily.lowercase()) {
                val brand = resultFields.firstOrNull { it.title == "Brand" }?.value
                if (!brand.isNullOrBlank() && brand != "T-Union Cities") return brand
                if (!region.isNullOrBlank()) return region
            }
            return region ?: resolveJapaneseBrand(realSerialNumber ?: customDisplaySerialNumber) ?: cardFamily
        }

    val visibleBalance: String
        get() = balanceText?.takeIf { it.isNotBlank() }
            ?: resultFields.firstOrNull { it.title == "Remaining Trips" }?.value?.let { "$it trips" }
            ?: ""

    val finalIsUsingImage: Boolean get() = isUsingImage ?: (faceImageFileName != null)
    val finalHideTitle: Boolean get() = hideTitleOnImage ?: false
    val finalHideSerialNumber: Boolean get() = hideSerialNumber ?: false
    val markerText: String?
        get() = markerSymbolName?.takeIf { it.startsWith("txt:") }?.drop(4)
    val markerSystemName: String?
        get() = markerSymbolName?.takeIf { it.startsWith("sf:") }?.drop(3)

    val displayedSerialNumber: String
        get() {
            val raw = customDisplaySerialNumber?.takeIf { it.isNotBlank() }
                ?: realSerialNumber
                ?: identifierValue
            if (technology == "FeliCa") {
                val formatted = formattedFeliCaSerial(raw)
                if (formatted.isNotBlank()) return formatted
            }
            return raw
        }

    companion object {
        fun from(snapshot: TransitCardSnapshot) = SavedCardRecord(
            id = snapshot.storageIdentifier,
            cardFamily = snapshot.cardFamily,
            technology = snapshot.technology,
            identifierLabel = snapshot.identifierLabel,
            rawIdentifierValue = snapshot.rawIdentifierValue,
            identifierValue = snapshot.identifierValue,
            pmm = snapshot.pmm,
            selectedAID = snapshot.selectedAID,
            systemCode = snapshot.systemCode,
            balanceText = snapshot.balanceText,
            balanceDetail = snapshot.balanceDetail,
            realSerialNumber = snapshot.realSerialNumber,
            region = snapshot.region
                ?: snapshot.resultFields.firstOrNull { it.title == "Brand" }?.value
                ?: snapshot.resultFields.firstOrNull { it.title == "Region" }?.value,
            applications = snapshot.applications,
            rawTransactions = snapshot.rawTransactions,
            rawTransitHistory = snapshot.rawTransitHistory,
            resultFields = snapshot.resultFields.map { SavedCardField(it.title, it.value) },
            scannedAt = snapshot.scannedAt,
            color = SavedCardColor.defaultFor(snapshot.cardFamily),
        )

        fun resolveJapaneseBrand(serialNumber: String?): String? {
            val sn = serialNumber?.uppercase()?.filter { it.isLetterOrDigit() }.orEmpty()
            return listOf(
                "JE" to "Suica", "PB" to "PASMO", "JW" to "ICOCA", "FC" to "Hayakaken",
                "JK" to "SUGOCA", "TP" to "Manaca", "JH" to "Kitaca", "NR" to "Nimoca",
                "JC" to "TOICA",
            ).firstOrNull { sn.startsWith(it.first) }?.second
        }

        private fun formattedFeliCaSerial(raw: String): String {
            val normalized = raw.uppercase().filter { it.isLetterOrDigit() }
            if (normalized.isBlank()) return ""
            if (normalized.length == 17) {
                val groups = mutableListOf(normalized.take(5))
                normalized.drop(5).chunked(4).forEach(groups::add)
                return groups.joinToString(" ")
            }
            return normalized.chunked(4).joinToString(" ")
        }
    }
}
