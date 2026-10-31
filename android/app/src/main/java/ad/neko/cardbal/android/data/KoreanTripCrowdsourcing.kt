package ad.neko.cardbal.android.data

import android.content.Context
import android.content.SharedPreferences
import ad.neko.cardbal.android.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest

/** "Help Improve Korean Cards", as on iPhone: on by default, and the user can turn it off. */
object KoreanTripCrowdsourcingPreferences {
    const val PREFERENCES = "korean_trip_crowdsourcing"
    const val ENABLED_KEY = "koreanTripCrowdsourcingEnabled"
    const val UPLOADED_HASHES_KEY = "koreanTripCrowdsourcingUploadedHashes"
    const val ENDPOINT = "https://korean-trip-crowdsourcing.ieb.app/ingest/korean-trip-records"
    const val SOURCE = "cardbal-android"
    /** At most this many uploaded record hashes are remembered, the most recent first kept. */
    const val MAX_UPLOADED_HASHES = 5000
}

/** Key names match the iPhone upload exactly. */
@Serializable
data class KoreanTripCrowdsourcingRecord(
    val dedupHash: String,
    val hashedCardID: String,
    val cardIDLast4: String,
    val bytes0508: String,
    val bytes090A: String,
    val allBytes: String,
    val cardFamily: String,
)

@Serializable
internal data class KoreanTripCrowdsourcingEnvelope(
    val records: List<KoreanTripCrowdsourcingRecord>,
    val source: String,
    val appVersion: String,
)

object KoreanTripCrowdsourcing {
    fun isEligible(snapshot: TransitCardSnapshot): Boolean =
        snapshot.technology == "ISO7816" && isKoreanTripBrand(snapshot.cardFamily) &&
            snapshot.rawTransitHistory.isNotEmpty() && stableCardID(snapshot) != null

    /** T-money and EZL/Cashbee, matched as the iPhone matches card brands by family name. */
    fun isKoreanTripBrand(family: String): Boolean {
        val f = family.trim().lowercase()
        if (f.startsWith("ez-link") || f.startsWith("ezlink") || f.startsWith("cepas")) return false
        return f == "t-money" || f == "tmoney" || f == "ezl" || f == "cashbee" ||
            f.startsWith("t-money") || f.startsWith("ezl") || f.startsWith("cashbee")
    }

    fun stableCardID(snapshot: TransitCardSnapshot): String? {
        val raw = snapshot.realSerialNumber?.takeIf { it.isNotEmpty() } ?: snapshot.identifierValue
        return normalizeCardID(raw).ifEmpty { null }
    }

    fun makeRecords(snapshot: TransitCardSnapshot): List<KoreanTripCrowdsourcingRecord> {
        val stableCardID = stableCardID(snapshot) ?: return emptyList()
        val hashedCardID = sha256Hex(stableCardID)
        val last4 = stableCardID.takeLast(4)
        return snapshot.rawTransitHistory.mapNotNull { hex ->
            val normalizedHex = hex.trim().uppercase()
            val data = hexData(normalizedHex)
            if (data.isEmpty()) return@mapNotNull null
            KoreanTripCrowdsourcingRecord(
                dedupHash = sha256Hex(stableCardID + normalizedHex),
                hashedCardID = hashedCardID,
                cardIDLast4 = last4,
                bytes0508 = if (data.size >= 9) data.copyOfRange(5, 9).upperHex() else "",
                bytes090A = if (data.size >= 11) data.copyOfRange(9, 11).upperHex() else "",
                allBytes = normalizedHex,
                cardFamily = snapshot.cardFamily,
            )
        }
    }

    private fun normalizeCardID(value: String): String = value.uppercase().filter {
        it.isLetter() || it.category in setOf(CharCategory.DECIMAL_DIGIT_NUMBER, CharCategory.LETTER_NUMBER, CharCategory.OTHER_NUMBER)
    }

    internal fun sha256Hex(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** Reads hex as the iPhone does: anything but hex digits is skipped, and an odd count gains a leading zero. */
    internal fun hexData(text: String): ByteArray {
        var digits = text.filter { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
        if (digits.length % 2 != 0) digits = "0$digits"
        return ByteArray(digits.length / 2) { digits.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private fun ByteArray.upperHex() = joinToString("") { "%02X".format(it) }
}

/**
 * Sends new trip records of eligible Korean scans. Failures are ignored without retrying;
 * records that were not accepted are offered again on the card's next scan.
 */
class KoreanTripCrowdsourcingUploader internal constructor(
    private val preferences: SharedPreferences,
    private val endpoint: String = KoreanTripCrowdsourcingPreferences.ENDPOINT,
    private val appVersion: String = BuildConfig.VERSION_NAME,
    private val allowLoopback: Boolean = false,
    private val timeoutMillis: Int = REQUEST_TIMEOUT_MILLIS,
) {
    companion object {
        /** The iPhone uses the system default request timeout, which is 60 seconds. */
        const val REQUEST_TIMEOUT_MILLIS = 60_000
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        @Volatile private var shared: KoreanTripCrowdsourcingUploader? = null

        fun get(context: Context): KoreanTripCrowdsourcingUploader = shared ?: synchronized(this) {
            shared ?: KoreanTripCrowdsourcingUploader(
                context.applicationContext.getSharedPreferences(KoreanTripCrowdsourcingPreferences.PREFERENCES, 0),
            ).also { shared = it }
        }
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val hashList = ListSerializer(String.serializer())
    private val lock = Mutex()
    private var uploadedHashes: LinkedHashSet<String>? = null

    val isEnabled: Boolean get() = preferences.getBoolean(KoreanTripCrowdsourcingPreferences.ENABLED_KEY, true)

    /** Starts the upload in the background after a scan has been saved; the scan never waits for it. */
    fun launch(snapshot: TransitCardSnapshot) {
        if (!KoreanTripCrowdsourcing.isEligible(snapshot) || !isEnabled) return
        scope.launch { lock.withLock { upload(snapshot) } }
    }

    /** Uploads the records not sent before. Returns the number the server accepted with a 2xx reply. */
    internal fun upload(snapshot: TransitCardSnapshot): Int {
        if (!isEnabled || !KoreanTripCrowdsourcing.isEligible(snapshot)) return 0
        val hashes = uploadedHashes ?: loadHashes().also { uploadedHashes = it }
        val fresh = KoreanTripCrowdsourcing.makeRecords(snapshot).filter { it.dedupHash !in hashes }
        if (fresh.isEmpty()) return 0
        val body = json.encodeToString(KoreanTripCrowdsourcingEnvelope(fresh, KoreanTripCrowdsourcingPreferences.SOURCE, appVersion))
        if (!runCatching { post(body.toByteArray(Charsets.UTF_8)) }.getOrDefault(false)) return 0
        fresh.forEach { hashes.remove(it.dedupHash); hashes.add(it.dedupHash) }
        while (hashes.size > KoreanTripCrowdsourcingPreferences.MAX_UPLOADED_HASHES) hashes.remove(hashes.first())
        preferences.edit().putString(KoreanTripCrowdsourcingPreferences.UPLOADED_HASHES_KEY, json.encodeToString(hashList, hashes.toList())).apply()
        return fresh.size
    }

    private fun loadHashes(): LinkedHashSet<String> = runCatching {
        preferences.getString(KoreanTripCrowdsourcingPreferences.UPLOADED_HASHES_KEY, null)
            ?.let { LinkedHashSet(json.decodeFromString(hashList, it)) }
    }.getOrNull() ?: LinkedHashSet()

    private fun post(body: ByteArray): Boolean {
        val uri = URI(endpoint)
        if (uri.host.isNullOrEmpty() || !(uri.scheme == "https" ||
                allowLoopback && uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost", "[::1]"))) return false
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            if (connection.responseCode !in 200..299) return false
            // The reply ({accepted, duplicates}) is informational; read it so a broken transfer counts as a failure.
            connection.inputStream.use { input ->
                val buffer = ByteArray(4096)
                while (input.read(buffer) >= 0) Unit
            }
            return true
        } finally {
            connection.disconnect()
        }
    }
}
