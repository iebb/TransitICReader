package ad.neko.cardbal.android.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Card faces published from github.com/iebb/card-faces, shared with the
 * iPhone app. A face is stored as a `remote.…png` token and downloaded on
 * demand into filesDir/RemoteFaces, outside the backed-up CardFaces folder.
 */
@Serializable
data class RemoteFaceManifest(val schemaVersion: Int, val cards: List<Card> = emptyList()) {
    @Serializable
    data class Match(
        val cityCodes: List<String> = emptyList(),
        val cityUnionCodes: List<String> = emptyList(),
        val cardPrefixes: List<String> = emptyList(),
        val families: List<String> = emptyList(),
        val serialPrefixes: List<String> = emptyList(),
    )

    @Serializable
    data class Design(
        val id: String,
        val name: Map<String, String>? = null,
        val bundledAsset: String? = null,
        val file: String,
        val sha256: String,
        val bytes: Int,
    )

    @Serializable
    data class Card(
        val id: String,
        val name: Map<String, String> = emptyMap(),
        val city: Map<String, String>? = null,
        val match: Match = Match(),
        val designs: List<Design> = emptyList(),
    )

    data class Entry(val token: String, val card: Card, val design: Design)

    val entries: List<Entry> by lazy {
        cards.flatMap { card -> card.designs.map { Entry(token(card.id, it.id), card, it) } }
    }

    fun entry(token: String): Entry? = entries.firstOrNull { it.token == token }

    /**
     * T-Union city code, then City Union city code, then the longest card
     * number prefix, the longest family-name substring and the serial prefix.
     */
    fun match(input: RemoteFaceMatchInput): Card? {
        input.tUnionCityCodes.filter { it.isNotBlank() }.map { it.uppercase() }.forEach { code ->
            cards.firstOrNull { code in it.match.cityCodes }?.let { return it }
        }
        input.cityUnionCodes.filter { it.isNotBlank() }.map { it.uppercase() }.forEach { code ->
            cards.firstOrNull { code in it.match.cityUnionCodes }?.let { return it }
        }
        val digits = input.serialNumbers.map { serial -> serial.filter { it in '0'..'9' } }.filter { it.isNotEmpty() }
        longestMatch({ it.cardPrefixes }) { prefix -> digits.any { it.startsWith(prefix) } }?.let { return it }
        val family = input.family.lowercase()
        if (family.isNotEmpty()) {
            longestMatch({ it.families }) { it in family }?.let { return it }
        }
        val serials = input.serialNumbers.map { serial -> serial.uppercase().filter { it.isLetterOrDigit() } }
        return longestMatch({ it.serialPrefixes }) { prefix -> serials.any { it.startsWith(prefix) } }
    }

    /**
     * The published face to draw for [card]: its own token, the published copy
     * of an iPhone preset it names, or the matched default when it has none.
     */
    fun faceTokenFor(card: SavedCardRecord): String? {
        val name = card.faceImageFileName
        if (name != null) {
            if (!card.finalIsUsingImage) return null
            if (isToken(name)) return name
            return entries.firstOrNull { it.design.bundledAsset == name }?.token ?: publishedToken(name)
        }
        if (card.isUsingImage == false) return null
        val matched = match(card.remoteFaceMatchInput()) ?: return null
        return matched.designs.firstOrNull { it.id == "default" }?.let { token(matched.id, it.id) }
    }

    /** Exact physical type first, then city peers in the same region, in manifest order. */
    fun relevantEntriesFor(input: RemoteFaceMatchInput): List<Entry> {
        val matched = match(input) ?: return emptyList()
        return entries.filter { it.card.id == matched.id } +
            entries.filter { it.card.id != matched.id && it.card.sharesCityWith(matched) }
    }

    private fun Card.sharesCityWith(other: Card): Boolean {
        val region = id.substringBefore('/')
        if (region.isBlank() || region != other.id.substringBefore('/')) return false
        fun List<String>.overlaps(values: List<String>): Boolean =
            any { it.isNotBlank() && it in values }
        fun Card.cityNames() = city?.values.orEmpty().map { it.trim().lowercase() }
        return match.cityCodes.overlaps(other.match.cityCodes) ||
            match.cityUnionCodes.overlaps(other.match.cityUnionCodes) ||
            cityNames().overlaps(other.cityNames())
    }

    /** Color, relevant presets, the saved choice/photo, then the remaining card groups. */
    fun pickerChoicesFor(card: SavedCardRecord, savedFaces: List<String> = emptyList()): List<CardFaceChoice> {
        fun canonicalName(name: String): String =
            entries.firstOrNull { it.design.bundledAsset == name }?.token ?: publishedToken(name) ?: name

        val current = card.faceImageFileName?.takeIf { it.isNotBlank() }?.let(::canonicalName)
        val active = if (card.isUsingImage == false) null else {
            faceTokenFor(card) ?: current ?: offlineAssetFor(card)?.let(::publishedToken)
        }
        val names = buildList {
            addAll(relevantEntriesFor(card.remoteFaceMatchInput()).map { it.token })
            current?.let(::add)
            active?.let(::add)
            addAll(savedFaces.filter { it.isNotBlank() }.map(::canonicalName))
            addAll(entries.map { it.token })
        }.distinct()
        return listOf(CardFaceChoice(fileName = null, selected = active == null)) +
            names.map { CardFaceChoice(it, entry(it), selected = it == active) }
    }

    private fun longestMatch(values: (Match) -> List<String>, matches: (String) -> Boolean): Card? =
        cards.flatMap { card -> values(card.match).filter { it.isNotBlank() && matches(it) }.map { card to it.length } }
            .maxByOrNull { it.second }?.first

    companion object {
        const val SUPPORTED_SCHEMA_VERSION = 2
        const val MAX_FACE_BYTES = 40_000
        private val tokenPattern = Regex("^remote(\\.[a-z0-9][a-z0-9-]*)+\\.png$")
        val json = Json { ignoreUnknownKeys = true }

        fun token(cardId: String, designId: String) = "remote.${cardId.replace('/', '.')}.$designId.png"

        fun isToken(fileName: String) = tokenPattern.matches(fileName)

        private val legacyCardIds = mapOf(
            "suica" to "jp/suica", "pasmo" to "jp/pasmo", "icoca" to "jp/icoca",
            "hayakaken" to "jp/hayakaken", "sugoca" to "jp/sugoca", "manaca" to "jp/manaca",
            "kitaca" to "jp/kitaca", "nimoca" to "jp/nimoca", "toica" to "jp/toica",
            "okica" to "jp/okica", "edy" to "jp/edy", "waon" to "jp/waon", "nanaco" to "jp/nanaco",
            "ezlink" to "sg/ezlink", "ezl" to "kr/ezl", "tmoney" to "kr/tmoney",
            "climate-card" to "kr/climate-card", "la-carte" to "fr/la-carte",
            "la-carte-blue" to "fr/la-carte", "umoney" to "mn/umoney",
        )
        private val offlineAssets = setOf("suica", "pasmo", "icoca", "tmoney", "ezl")

        /** Resolve old bundle names even before a fresh install gets its first manifest. */
        fun publishedToken(fileName: String): String? {
            if (isToken(fileName)) return fileName
            val id = legacyCardIds[fileName] ?: return null
            return token(id, if (fileName == "la-carte-blue") "blue" else "default")
        }

        fun offlineAsset(fileName: String): String? =
            offlineAssets.firstOrNull { it == fileName || publishedToken(it) == fileName }

        /** A bundled fallback never overrides a photo, alternate design or explicit color-only choice. */
        fun offlineAssetFor(card: SavedCardRecord): String? {
            if (card.isUsingImage == false) return null
            card.faceImageFileName?.let { return offlineAsset(it) }
            val family = card.cardFamily.lowercase().replace("-", "").replace(" ", "")
            if ("ezlink" in family) return null
            return when {
                "suica" in family -> "suica"
                "pasmo" in family -> "pasmo"
                "icoca" in family -> "icoca"
                "tmoney" in family -> "tmoney"
                "ezl" in family || "cashbee" in family -> "ezl"
                else -> when (card.realSerialNumber?.uppercase()?.take(2)) {
                    "JE" -> "suica"
                    "PB" -> "pasmo"
                    "JW" -> "icoca"
                    else -> null
                }
            }
        }

        fun parse(text: String): RemoteFaceManifest? =
            runCatching { json.decodeFromString(serializer(), text) }.getOrNull()
                ?.takeIf { it.schemaVersion == SUPPORTED_SCHEMA_VERSION }
    }
}

data class RemoteFaceMatchInput(
    val tUnionCityCodes: List<String> = emptyList(),
    val cityUnionCodes: List<String> = emptyList(),
    val serialNumbers: List<String> = emptyList(),
    val family: String = "",
)

data class CardFaceChoice(
    val fileName: String?,
    val entry: RemoteFaceManifest.Entry? = null,
    val selected: Boolean = false,
)

/** Disabling artwork retains the saved photo/preset so it can be selected again. */
fun SavedCardRecord.withFaceChoice(fileName: String?): SavedCardRecord =
    if (fileName == null) copy(isUsingImage = false)
    else copy(faceImageFileName = fileName, isUsingImage = true)

fun SavedCardRecord.remoteFaceMatchInput(): RemoteFaceMatchInput {
    val apps = applications.orEmpty()
    val legacyCity = resultFields.firstOrNull { it.title == "City Code" }?.value
    return RemoteFaceMatchInput(
        tUnionCityCodes = apps.filter { it.isTUnion }.mapNotNull { it.cityCode?.takeIf(String::isNotBlank) }.ifEmpty {
            listOfNotNull(legacyCity.takeIf { selectedAID == "A000000632010105" })
        },
        cityUnionCodes = apps.filter { it.isCityUnion }.mapNotNull { it.cityCode?.takeIf(String::isNotBlank) }.ifEmpty {
            listOfNotNull(legacyCity.takeIf { selectedAID == "A00000000386980701" })
        },
        serialNumbers = listOfNotNull(realSerialNumber) + apps.mapNotNull { it.serialNumber },
        family = (listOf(cardFamily) + apps.map { it.cardFamily }).distinct().joinToString(" "),
    )
}

class RemoteCardFaces private constructor(context: Context) {
    private val directory = File(context.filesDir, "RemoteFaces")
    private val manifestFile = File(directory, "manifest.json")
    private val prefs = context.getSharedPreferences("remote_card_faces", Context.MODE_PRIVATE)
    private val refreshLock = Mutex()
    private val downloadLock = Mutex()
    private val _manifest = MutableStateFlow(
        runCatching { manifestFile.readText() }.getOrNull()?.let(RemoteFaceManifest::parse),
    )
    val manifest: StateFlow<RemoteFaceManifest?> = _manifest

    fun faceTokenFor(card: SavedCardRecord): String? {
        if (card.isUsingImage == false) return null
        return _manifest.value?.faceTokenFor(card)
            ?: card.faceImageFileName?.let(RemoteFaceManifest::publishedToken)
    }

    fun cachedFace(token: String): Bitmap? {
        if (!RemoteFaceManifest.isToken(token)) return null
        val file = File(directory, token)
        return if (file.isFile) BitmapFactory.decodeFile(file.absolutePath) else null
    }

    /** Fetches the manifest at most once a day, then drops faces it no longer lists. */
    suspend fun refreshIfNeeded(force: Boolean = false) = withContext(Dispatchers.IO) {
        refreshLock.withLock {
            val last = prefs.getLong(LAST_REFRESH_KEY, 0)
            if (!force && _manifest.value != null && System.currentTimeMillis() - last < REFRESH_INTERVAL_MS) {
                return@withLock
            }
            for (base in BASE_URLS) {
                val data = fetch("${base}manifest.json", MAX_MANIFEST_BYTES) ?: continue
                val manifest = RemoteFaceManifest.parse(data.decodeToString()) ?: continue
                directory.mkdirs()
                writeAtomically(manifestFile, data)
                prefs.edit().putLong(LAST_REFRESH_KEY, System.currentTimeMillis()).apply()
                removeStaleFaces(manifest)
                _manifest.value = manifest
                return@withLock
            }
        }
    }

    /** Returns the cached face or downloads it, verifying size and sha256. */
    suspend fun face(token: String): Bitmap? = withContext(Dispatchers.IO) {
        cachedFace(token)?.let { return@withContext it }
        if (_manifest.value?.entry(token) == null) refreshIfNeeded(force = _manifest.value != null)
        val design = _manifest.value?.entry(token)?.design ?: return@withContext null
        downloadLock.withLock {
            cachedFace(token)?.let { return@withLock it }
            for (base in BASE_URLS) {
                val data = fetch("$base${design.file}?v=${design.sha256.take(12)}", RemoteFaceManifest.MAX_FACE_BYTES) ?: continue
                if (data.size != design.bytes || sha256(data) != design.sha256.lowercase()) continue
                val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size) ?: continue
                directory.mkdirs()
                writeAtomically(File(directory, token), data)
                return@withLock bitmap
            }
            null
        }
    }

    private fun removeStaleFaces(manifest: RemoteFaceManifest) {
        directory.listFiles()?.filter { RemoteFaceManifest.isToken(it.name) }?.forEach { file ->
            val expected = manifest.entry(file.name)?.design?.sha256?.lowercase()
            if (expected == null || sha256(file.readBytes()) != expected) file.delete()
        }
    }

    private fun fetch(url: String, maxBytes: Int): ByteArray? = runCatching {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 20_000
        connection.useCaches = false
        try {
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return@runCatching null
            connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8_192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    if (output.size() > maxBytes) return@runCatching null
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }.getOrNull()

    private fun writeAtomically(target: File, data: ByteArray) {
        val temporary = File(target.parentFile, "${target.name}.tmp")
        temporary.writeBytes(data)
        if (!temporary.renameTo(target)) {
            target.delete()
            temporary.renameTo(target)
        }
    }

    companion object {
        /** Cloudflare Pages first; jsDelivr is reachable from mainland China. */
        val BASE_URLS = listOf(
            "https://faces.cardb.al/",
            "https://cdn.jsdelivr.net/gh/iebb/card-faces@master/",
            "https://raw.githubusercontent.com/iebb/card-faces/master/",
        )
        private const val LAST_REFRESH_KEY = "refreshed_at"
        private const val REFRESH_INTERVAL_MS = 24L * 60 * 60 * 1000
        private const val MAX_MANIFEST_BYTES = 1_000_000

        @Volatile private var instance: RemoteCardFaces? = null

        fun get(context: Context): RemoteCardFaces = instance ?: synchronized(this) {
            instance ?: RemoteCardFaces(context.applicationContext).also { instance = it }
        }

        fun sha256(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
    }
}
