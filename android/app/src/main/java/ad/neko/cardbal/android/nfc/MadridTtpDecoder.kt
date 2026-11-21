package ad.neko.cardbal.android.nfc

import android.content.SharedPreferences
import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.DebugLog
import ad.neko.cardbal.android.data.RawDataField
import ad.neko.cardbal.android.data.RawDataSection
import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.datetime.Instant

/** The iOS Madrid Online setting, with the same key and default. */
object MadridTtpPreferences {
    const val PREFERENCES = "madrid"
    const val ENABLED_KEY = "madridOnlineEnabled"
}

/**
 * Tarjeta Transporte Público, read through CRTM's card-reading service. The card must
 * have DESFire application 000001 before anything is sent to the service.
 */
class MadridTtpDecoder(private val preferences: SharedPreferences?) : TransitCardDecoder {
    companion object {
        const val FAMILY = "Tarjeta Transporte Público"

        fun snapshot(outcome: MadridTtpProtocol.Outcome, uid: ByteArray, scannedAt: Instant): TransitCardSnapshot {
            val card = outcome.card
            val serial = card.serial?.uppercase()?.takeIf { it.matches(Regex("[0-9A-F]{14}")) }
            val identifier = serial ?: uid.hexString().uppercase()
            return TransitCardSnapshot(
                technology = "DESFire", cardFamily = FAMILY, identifierLabel = "UID",
                identifierValue = identifier, rawIdentifierValue = identifier,
                realSerialNumber = card.cardNumber, region = "Madrid",
                resultFields = card.fields.map { ResultField(it.first, it.second) },
                rawSections = listOf(RawDataSection("CRTM Service", listOf(
                    RawDataField("Status", card.statusCode),
                    RawDataField("Rounds", outcome.rounds.toString()),
                    RawDataField("Card Commands", outcome.commands.toString()),
                    RawDataField("Response", card.summaryJson),
                ))),
                scannedAt = scannedAt,
            )
        }
    }

    override fun canDecode(tag: Tag): Boolean =
        IsoDep.get(tag) != null && preferences?.getBoolean(MadridTtpPreferences.ENABLED_KEY, true) == true

    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val connection = IsoDep.get(tag) ?: return null
        try {
            connection.connect()
            connection.timeout = 3000
            if (!connection.transceive(MadridTtpProtocol.SELECT_APPLICATION).contentEquals(byteArrayOf(0x91.toByte(), 0))) return null
            DebugLog.log("Madrid", "DESFire application 000001 found; reading through the CRTM service")
            val outcome = try {
                MadridTtpProtocol.read(MadridTtpClient()::post, connection::transceive) { DebugLog.log("Madrid", it) }
            } catch (error: Exception) {
                DebugLog.log("Madrid", "Read failed: " + DebugLog.describe(error))
                throw error
            }
            return snapshot(outcome, tag.id ?: ByteArray(0), scannedAt)
        } finally {
            runCatching { connection.close() }
        }
    }
}

/** CRTM's card-reading service. The session lives in cookies held only for one read. */
internal class MadridTtpClient(
    private val baseUrl: String = BASE_URL,
    private val deadlineNanos: Long = System.nanoTime() + 30_000_000_000,
) {
    companion object {
        const val BASE_URL = "https://latsecu.comunidad.madrid/middlelat"
        const val REQUEST_TIMEOUT_MILLIS = 10_000
    }
    private val cookies = sortedMapOf<String, String>()

    fun post(path: String, body: ByteArray): ByteArray {
        val remaining = (deadlineNanos - System.nanoTime()) / 1_000_000
        if (remaining <= 0) throw MadridTtpException.BudgetExceeded()
        val connection = URL(baseUrl + path).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = minOf(REQUEST_TIMEOUT_MILLIS.toLong(), remaining).toInt().coerceAtLeast(1)
            connection.readTimeout = connection.connectTimeout
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "CardBal")
            if (cookies.isNotEmpty()) connection.setRequestProperty("Cookie", cookies.entries.joinToString("; ") { "${it.key}=${it.value}" })
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            connection.headerFields.entries.filter { it.key.equals("Set-Cookie", ignoreCase = true) }.flatMap { it.value }.forEach { header ->
                val pair = header.substringBefore(';')
                val name = pair.substringBefore('=', "").trim()
                if (name.isNotEmpty()) cookies[name] = pair.substringAfter('=').trim()
            }
            if (status != 200 || connection.contentLengthLong > MadridTtpProtocol.MAX_BODY) {
                DebugLog.log("Madrid", "${if (path == MadridTtpProtocol.INIT_PATH) "Session" else "Reading"} request: HTTP $status")
                throw MadridTtpException.InvalidResponse()
            }
            return connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    if (System.nanoTime() >= deadlineNanos) throw MadridTtpException.BudgetExceeded()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > MadridTtpProtocol.MAX_BODY - output.size()) throw MadridTtpException.InvalidResponse()
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }
}
