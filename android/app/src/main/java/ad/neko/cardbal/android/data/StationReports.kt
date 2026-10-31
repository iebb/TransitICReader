package ad.neko.cardbal.android.data

import android.content.SharedPreferences
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.UUID

/** Mirrors the iOS StationReportView contract; `services/station-reports` rejects unknown keys. */
enum class StationReportKind(val wireValue: String, val title: String) {
    Missing("missing", "Missing Station"),
    Correction("correction", "Code Correction"),
}

@Serializable
data class StationReportLocationPayload(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double? = null,
)

/** Null optional fields are omitted from the JSON, like Swift's synthesized Encodable. */
@Serializable
data class StationReportPayload(
    val submissionId: String,
    val reportType: String,
    val stationName: String,
    val stationCode: String? = null,
    val suggestedCode: String? = null,
    val lines: String? = null,
    @SerialName("operator") val operatorName: String? = null,
    val city: String? = null,
    val country: String? = null,
    val notes: String? = null,
    val location: StationReportLocationPayload? = null,
    val cardFamily: String,
    val cardIdHash: String,
    val appVersion: String,
    val deviceId: String,
    val source: String,
)

/** Form values as typed; limits and trimming match iOS `canSubmit` and `submit()`. */
data class StationReportForm(
    val kind: StationReportKind = StationReportKind.Missing,
    val stationName: String = "",
    val stationCode: String = "",
    val suggestedCode: String = "",
    val lines: String = "",
    val operatorName: String = "",
    val city: String = "",
    val country: String = "",
    val notes: String = "",
) {
    val isComplete: Boolean get() =
        stationName.trim().isNotEmpty() && stationName.length <= StationReports.MAX_NAME &&
            (kind != StationReportKind.Correction || stationCode.trim().isNotEmpty()) &&
            stationCode.length <= StationReports.MAX_CODE && suggestedCode.length <= StationReports.MAX_CODE &&
            lines.length <= StationReports.MAX_LINES && operatorName.length <= StationReports.MAX_NAME &&
            city.length <= StationReports.MAX_NAME && country.length <= StationReports.MAX_NAME &&
            notes.length <= StationReports.MAX_NOTES

    fun canSubmit(isSubmitting: Boolean): Boolean = !isSubmitting && isComplete

    fun payload(
        submissionId: String,
        location: StationReportLocationPayload?,
        cardFamily: String,
        cardIdHash: String,
        appVersion: String,
        deviceId: String,
    ): StationReportPayload = StationReportPayload(
        submissionId = submissionId,
        reportType = kind.wireValue,
        stationName = stationName.trim(),
        stationCode = stationCode.optionalValue(),
        suggestedCode = if (kind == StationReportKind.Correction) suggestedCode.optionalValue() else null,
        lines = lines.optionalValue(),
        operatorName = operatorName.optionalValue(),
        city = city.optionalValue(),
        country = country.optionalValue(),
        notes = notes.optionalValue(),
        location = location,
        cardFamily = cardFamily,
        cardIdHash = cardIdHash,
        appVersion = appVersion,
        deviceId = deviceId,
        source = StationReports.SOURCE,
    )

    private fun String.optionalValue(): String? = trim().takeIf { it.isNotEmpty() }
}

object StationReports {
    const val ENDPOINT = "https://cardbal.ieb.app/api/v1/station-reports"
    const val SOURCE = "android"
    const val PREFERENCES = "station_reports"
    const val DEVICE_ID_KEY = "stationReportDeviceID"
    const val MAX_NAME = 120
    const val MAX_CODE = 64
    const val MAX_LINES = 240
    const val MAX_NOTES = 1200
    /** Matches the server's UUID check, so a stored ID is always accepted. */
    private val uuidPattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOption.IGNORE_CASE)

    val json = Json { ignoreUnknownKeys = true }

    fun newSubmissionId(): String = UUID.randomUUID().toString().lowercase()

    fun deviceId(preferences: SharedPreferences): String {
        preferences.getString(DEVICE_ID_KEY, null)?.takeIf { uuidPattern.matches(it) }?.let { return it }
        val created = UUID.randomUUID().toString().lowercase()
        preferences.edit().putString(DEVICE_ID_KEY, created).apply()
        return created
    }

    /** SHA-256 of the saved card ID (`SavedCardRecord.id`), as lowercase hex. */
    fun cardIdHash(cardId: String): String =
        MessageDigest.getInstance("SHA-256").digest(cardId.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** The single distinct non-blank entry/exit station code of a record, if any. */
    fun prefilledStationCode(tx: TransitTransaction): String? {
        val codes = listOf(tx.entryStationCode, tx.exitStationCode).mapNotNull { it?.trim() }.filter { it.isNotEmpty() }
        return if (codes.toSet().size == 1) codes.first() else null
    }

    /** Keeps a picked map coordinate inside the server's latitude/longitude ranges. */
    fun location(latitude: Double, longitude: Double, accuracyMeters: Double? = null): StationReportLocationPayload? {
        if (!latitude.isFinite() || !longitude.isFinite()) return null
        val wrapped = ((longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
        return StationReportLocationPayload(
            latitude = latitude.coerceIn(-90.0, 90.0),
            longitude = wrapped,
            accuracyMeters = accuracyMeters?.takeIf { it.isFinite() && it in 0.0..100_000.0 },
        )
    }
}

class StationReportException(message: String) : IOException(message)

class StationReportClient(
    private val endpoint: String = StationReports.ENDPOINT,
    private val allowLoopback: Boolean = false,
    private val timeoutMillis: Int = 30_000,
) {
    companion object {
        private const val MAX_RESPONSE_BYTES = 65_536
    }

    /** Sends one report and returns the server's reference ID; throws on any failure. */
    fun submit(payload: StationReportPayload): String {
        val uri = URI(endpoint)
        if (uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
            !(uri.scheme == "https" || allowLoopback && uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost", "[::1]"))) {
            throw StationReportException("Invalid station report endpoint")
        }
        val body = StationReports.json.encodeToString(StationReportPayload.serializer(), payload).toByteArray(Charsets.UTF_8)
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.useCaches = false
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("User-Agent", "CardBal-Android/${payload.appVersion}")
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            if (status !in 200..299) throw StationReportException("Station report failed with HTTP $status")
            val response = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > MAX_RESPONSE_BYTES - output.size()) throw StationReportException("Oversized response")
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            }
            val id = runCatching { StationReports.json.parseToJsonElement(response) as? JsonObject }.getOrNull()
                ?.get("id") as? JsonPrimitive
            return id?.takeIf { it.isString && it.content.isNotBlank() }?.content
                ?: throw StationReportException("Station report response has no ID")
        } finally {
            connection.disconnect()
        }
    }
}
