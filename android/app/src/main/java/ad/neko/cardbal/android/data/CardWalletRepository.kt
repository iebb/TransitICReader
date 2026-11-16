package ad.neko.cardbal.android.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.charset.StandardCharsets

@Serializable
data class CardBackupData(
    val version: Int = 1,
    val cards: List<SavedCardRecord>,
    val faceAssets: Map<String, String> = emptyMap(),
)

data class CardImportResult(
    val imported: Int,
    val replaced: Int,
)

class CardWalletRepository(context: Context, private val sampleWallet: Boolean = false) {
    private val appContext = context.applicationContext
    private val faceDirectory = File(appContext.filesDir, "CardFaces")
    private val db = CardDb(appContext, if (sampleWallet) "samples.sqlite" else "cards.sqlite").writableDatabase
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val _cards = MutableStateFlow(loadCards())
    val cards: StateFlow<List<SavedCardRecord>> = _cards

    /** Reload an explicitly requested development wallet without touching saved cards. */
    fun loadDevelopmentSamples(bytes: ByteArray) {
        check(sampleWallet) { "Development samples require a separate wallet" }
        val backup = json.decodeFromString<CardBackupData>(bytes.toString(StandardCharsets.UTF_8))
        require(backup.faceAssets.isEmpty() && backup.cards.all { it.faceImageFileName == null && it.isUsingImage != true }) {
            "Development samples must not contain artwork"
        }
        db.beginTransaction()
        try {
            db.delete("cards", null, null)
            backup.cards.forEach(::persist)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        _cards.value = loadCards()
    }

    fun upsert(snapshot: TransitCardSnapshot) {
        val before = _cards.value
        _cards.value = store(before, upsertingSnapshot(before, snapshot))
    }

    fun delete(id: String) {
        db.delete("cards", "id = ?", arrayOf(id))
        _cards.value = _cards.value.filterNot { it.id == id }
    }

    fun rename(id: String, title: String) = update(id) { it.copy(customTitle = title.trim().ifEmpty { null }) }

    fun setFace(id: String, fileName: String?) = update(id) { it.withFaceChoice(fileName) }

    /** Applies an appearance edit from the Customize Card screen. */
    fun customize(id: String, change: (SavedCardRecord) -> SavedCardRecord) = update(id, change)

    fun setRealSerialNumber(id: String, serialNumber: String) = update(id) {
        val clean = serialNumber.uppercase().trim()
        it.copy(
            realSerialNumber = clean,
            cardFamily = SavedCardRecord.resolveJapaneseBrand(clean) ?: it.cardFamily,
        )
    }

    fun exportBackup(): ByteArray {
        val referencedFaces = _cards.value.mapNotNull { it.faceImageFileName }.toSet()
        val faceAssets = referencedFaces.mapNotNull { fileName ->
            val file = File(faceDirectory, fileName)
            if (!file.isFile) return@mapNotNull null
            fileName to Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
        }.toMap()
        return json.encodeToString(CardBackupData(cards = _cards.value, faceAssets = faceAssets))
            .toByteArray(StandardCharsets.UTF_8)
    }

    fun importBackup(bytes: ByteArray): CardImportResult {
        val text = bytes.toString(StandardCharsets.UTF_8)
        val backup = json.decodeFromString<CardBackupData>(text)
        if (backup.faceAssets.isNotEmpty()) {
            faceDirectory.mkdirs()
            backup.faceAssets.forEach { (fileName, encoded) ->
                val cleanName = fileName.substringAfterLast('/').substringAfterLast('\\')
                if (cleanName.isBlank()) return@forEach
                File(faceDirectory, cleanName).writeBytes(Base64.decode(encoded, Base64.DEFAULT))
            }
        }
        val before = _cards.value
        val current = before.associateBy { it.id }.toMutableMap()
        var replaced = 0
        for (card in backup.cards) {
            if (current.containsKey(card.id)) replaced += 1
            current[card.id] = card
        }
        _cards.value = store(before, consolidateMatchingCards(current.values.sortedWith(walletOrder)))
        return CardImportResult(imported = backup.cards.size, replaced = replaced)
    }

    /**
     * Merge cards decoded from another app's backup. A matching card keeps its id,
     * appearance and place, and each application keeps its newest reading, so an
     * older backup adds history without rolling back a balance.
     */
    fun importSnapshots(snapshots: List<TransitCardSnapshot>): CardImportResult {
        val before = _cards.value
        val current = before.toMutableList()
        var replaced = 0
        for (snapshot in snapshots) {
            val incoming = SavedCardRecord.from(snapshot)
            val index = current.indexOfFirst { it.id == incoming.id || it.sharesApplication(incoming) }
            if (index < 0) {
                current.add(0, incoming)
                continue
            }
            current[index] = current[index].mergingImported(incoming)
            replaced += 1
        }
        _cards.value = store(before, consolidateMatchingCards(current))
        return CardImportResult(imported = snapshots.size, replaced = replaced)
    }

    private fun update(id: String, mutate: (SavedCardRecord) -> SavedCardRecord) {
        val cards = _cards.value.toMutableList()
        val index = cards.indexOfFirst { it.id == id }
        if (index < 0) return
        cards[index] = mutate(cards[index])
        persist(cards[index])
        _cards.value = cards
    }

    private fun persist(card: SavedCardRecord) {
        val stmt = db.compileStatement("INSERT OR REPLACE INTO cards (id, json_data) VALUES (?, ?)")
        stmt.bindString(1, card.id)
        stmt.bindString(2, json.encodeToString(card))
        stmt.executeInsert()
        stmt.close()
    }

    /** Write the entries that changed from [before] and delete those merged away. */
    private fun store(before: List<SavedCardRecord>, after: List<SavedCardRecord>): List<SavedCardRecord> {
        val kept = after.map { it.id }.toSet()
        db.beginTransaction()
        try {
            after.filter { it !in before }.forEach(::persist)
            before.map { it.id }.filter { it !in kept }.forEach { db.delete("cards", "id = ?", arrayOf(it)) }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return after.sortedWith(walletOrder)
    }

    private fun loadCards(): List<SavedCardRecord> {
        val cards = mutableListOf<SavedCardRecord>()
        db.rawQuery("SELECT json_data FROM cards", emptyArray()).use { cursor ->
            while (cursor.moveToNext()) {
                runCatching {
                    json.decodeFromString<SavedCardRecord>(cursor.getString(0))
                }.getOrNull()?.let(cards::add)
            }
        }
        val sorted = cards.sortedWith(walletOrder)
        // Entries of one card saved apart by earlier versions (Macau Pass beside its T-Union side) become one.
        val consolidated = consolidateMatchingCards(sorted)
        return if (consolidated.size == sorted.size) sorted else store(sorted, consolidated)
    }
}

private val walletOrder = compareBy<SavedCardRecord> { it.order }.thenByDescending { it.scannedAt }

/** The same application of the same card, identified by its serial. */
internal fun SavedCardRecord.sharesApplication(other: SavedCardRecord): Boolean {
    fun SavedCardRecord.keys() = (applications ?: listOf(TransitApplication.fromSaved(this)))
        .mapNotNull { app -> app.serialNumber?.takeIf { it.isNotBlank() }?.let { "${app.id}|$it" } }.toSet()
    return keys().any(other.keys()::contains)
}

/** Keep this card's id and appearance; each application keeps its newest reading. */
internal fun SavedCardRecord.mergingImported(incoming: SavedCardRecord): SavedCardRecord =
    withApplications(TransitApplication.merge(
        applications ?: listOf(TransitApplication.fromSaved(this)), incoming.applications.orEmpty(),
    )).copy(
        scannedAt = maxOf(scannedAt, incoming.scannedAt),
        resultFields = if (incoming.scannedAt > scannedAt) incoming.resultFields else resultFields,
    )

private class CardDb(context: Context, name: String) : SQLiteOpenHelper(context, name, null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, json_data TEXT NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
}
