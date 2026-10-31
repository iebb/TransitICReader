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
        val current = _cards.value.toMutableList()
        val index = cardIndexForSnapshot(current, snapshot)
        val incomingFields = snapshot.resultFields.map { SavedCardField(it.title, it.value) }
        val updated = if (index >= 0) {
            val existing = current[index]
            existing.copy(
                id = snapshot.storageIdentifier,
                cardFamily = snapshot.cardFamily,
                applications = if(snapshot.applications.isNullOrEmpty()) existing.applications else TransitApplication.merge(existing.applications ?: listOf(TransitApplication.fromSaved(existing)), snapshot.applications),
                balanceText = snapshot.balanceText,
                balanceDetail = snapshot.balanceDetail,
                resultFields = incomingFields,
                scannedAt = snapshot.scannedAt,
                pmm = snapshot.pmm,
                systemCode = snapshot.systemCode,
                selectedAID = snapshot.selectedAID,
                realSerialNumber = snapshot.realSerialNumber?.takeIf { it.isNotBlank() } ?: existing.realSerialNumber,
                rawTransactions = mergeCardHistory(snapshot.cardFamily, existing.rawTransactions, snapshot.rawTransactions),
                rawTransitHistory = mergeCardHistory(snapshot.cardFamily, existing.rawTransitHistory, snapshot.rawTransitHistory),
                region = snapshot.region
                    ?: snapshot.resultFields.firstOrNull { it.title == "Brand" }?.value
                    ?: snapshot.resultFields.firstOrNull { it.title == "Region" }?.value
                    ?: existing.region,
            )
        } else {
            SavedCardRecord.from(snapshot)
        }

        val previousId = current.getOrNull(index)?.id
        db.beginTransaction()
        try {
            persist(updated)
            if (previousId != null && previousId != updated.id) db.delete("cards", "id = ?", arrayOf(previousId))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        if (index >= 0) current[index] = updated else current.add(0, updated)
        _cards.value = current.sortedWith(compareBy<SavedCardRecord> { it.order }.thenByDescending { it.scannedAt })
    }

    fun delete(id: String) {
        db.delete("cards", "id = ?", arrayOf(id))
        _cards.value = _cards.value.filterNot { it.id == id }
    }

    fun rename(id: String, title: String) = update(id) { it.copy(customTitle = title.trim().ifEmpty { null }) }

    fun setFace(id: String, fileName: String?) = update(id) { it.withFaceChoice(fileName) }

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
        val current = _cards.value.associateBy { it.id }.toMutableMap()
        var replaced = 0
        for (card in backup.cards) {
            if (current.containsKey(card.id)) replaced += 1
            current[card.id] = card
            persist(card)
        }
        val merged = current.values.sortedWith(compareBy<SavedCardRecord> { it.order }.thenByDescending { it.scannedAt })
        _cards.value = merged
        return CardImportResult(imported = backup.cards.size, replaced = replaced)
    }

    /**
     * Merge cards decoded from another app's backup. A matching card keeps its id,
     * appearance and place, and each application keeps its newest reading, so an
     * older backup adds history without rolling back a balance.
     */
    fun importSnapshots(snapshots: List<TransitCardSnapshot>): CardImportResult {
        val current = _cards.value.toMutableList()
        var replaced = 0
        db.beginTransaction()
        try {
            for (snapshot in snapshots) {
                val incoming = SavedCardRecord.from(snapshot)
                val index = current.indexOfFirst { it.id == incoming.id || it.sharesApplication(incoming) }
                if (index < 0) {
                    current.add(0, incoming)
                    persist(incoming)
                    continue
                }
                val existing = current[index]
                val merged = existing.mergingImported(incoming)
                current[index] = merged
                persist(merged)
                replaced += 1
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        _cards.value = current.sortedWith(compareBy<SavedCardRecord> { it.order }.thenByDescending { it.scannedAt })
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

    private fun loadCards(): List<SavedCardRecord> {
        val cards = mutableListOf<SavedCardRecord>()
        db.rawQuery("SELECT json_data FROM cards", emptyArray()).use { cursor ->
            while (cursor.moveToNext()) {
                runCatching {
                    json.decodeFromString<SavedCardRecord>(cursor.getString(0))
                }.getOrNull()?.let(cards::add)
            }
        }
        return cards.sortedWith(compareBy<SavedCardRecord> { it.order }.thenByDescending { it.scannedAt })
    }
}

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
