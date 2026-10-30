package ad.neko.cardbal.android.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import ad.neko.cardbal.android.nfc.Iso7816Decoder
import ad.neko.cardbal.android.nfc.Iso7816Protocol
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import java.io.File
import java.io.InputStream
import java.util.UUID

/**
 * Imports cards from a 读卡识途 (Trip Reader) Android backup.
 *
 * The backup is the app's Room history database. `card_table` keeps each card's
 * SFI 0x15 issuer file and last balance per application; `tran_table` keeps the
 * accumulated raw records: `txCUResult` is a 23-byte PBOC ledger record from
 * file `txSFI`, `txTUResult` a 48-byte T-Union SFI 0x1E travel record. CardBal
 * replays those files through its own reader, so an imported card decodes and
 * merges exactly like a scan. Other card families are skipped.
 */
object TripReaderBackup {
    const val CITY_UNION_AID = "A00000000386980701"
    const val T_UNION_AID = "A000000632010105"
    /** Trip Reader's "no reading" sentinel for its balance columns. */
    private const val UNKNOWN_BALANCE = -99_999_999L

    class Application(val file15: ByteArray?, val balanceCents: Long?, val records: Map<Int, List<ByteArray>> = emptyMap()) {
        val recordCount get() = records.values.sumOf { it.size }
    }
    data class Card(val rawNumber: String, val lastUpdate: Instant, val applications: Map<String, Application>)
    data class CardRow(
        val rawNumber: String, val lastUpdate: Long?, val isTUnion: Boolean, val isCityUnion: Boolean,
        val balance: Long, val cityUnionBalance: Long, val tUnionBalance: Long,
        val cityUnionInfo: String?, val tUnionInfo: String?,
    )
    data class TransactionRow(
        val rawNumber: String, val ledger: String?, val travel: String?, val sfi: Int,
        val cityUnionLedger: Boolean, val tUnionLedger: Boolean, val tUnionTravel: Boolean,
    )
    data class ImportPlan(val snapshots: List<TransitCardSnapshot>, val recordCount: Int, val skippedCards: Int)
    class NotTripReaderBackupException : IllegalArgumentException("This file is not a Trip Reader backup.")

    private val requiredColumns = mapOf(
        "card_table" to setOf("cdRawNo", "cdLastUpdate", "isTU", "isCU", "cdBalance", "cdCUBalance", "cdTUBalance", "cdCURawInfo", "cdTURawInfo"),
        "tran_table" to setOf("cdRawNo", "txCUResult", "txTUResult", "txSFI", "txCU", "txCUTopUp", "txCUForeign", "txTU", "txTU18", "txTUTopUp"),
    )

    /** Read a picked document. SQLite needs a file path, and may add sidecars to a WAL database. */
    fun importPlan(context: Context, input: InputStream): ImportPlan {
        val directory = File(context.cacheDir, "tripreader-import-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val copy = File(directory, "backup.sqlite")
            copy.outputStream().use { input.copyTo(it) }
            return importPlan(readCards(copy))
        } finally {
            directory.deleteRecursively()
        }
    }

    fun importPlan(cards: List<Card>): ImportPlan {
        val snapshots = mutableListOf<TransitCardSnapshot>()
        var records = 0
        var skipped = 0
        for (card in cards) {
            val snapshot = snapshot(card)
            if (snapshot == null) { skipped += 1; continue }
            snapshots += snapshot
            records += card.applications.values.sumOf { it.recordCount }
        }
        return ImportPlan(snapshots, records, skipped)
    }

    /**
     * Decode one backed-up card with the production reader, then attach its full
     * history. A card file holds at most 30 records; the backup can hold more.
     */
    fun snapshot(card: Card): TransitCardSnapshot? {
        if (card.applications.isEmpty()) return null
        val replay = ReplayCard(card.applications)
        val decoder = Iso7816Decoder()
        val snapshots = Iso7816Protocol.applications.filter { it.currency == "CNY" }.mapNotNull { application ->
            val selection = Iso7816Protocol.select(application.aid, replay::exchange) ?: return@mapNotNull null
            decoder.readApplication("", selection, card.lastUpdate, replay::exchange)
        }
            // The wallet identifies these cards by serial; the backup has no UID.
            .filter { !it.realSerialNumber.isNullOrBlank() }
            .map { snapshot ->
                snapshot.copy(applications = snapshot.applications?.map { app ->
                    app.selectedAID?.let(card.applications::get)?.let { app.copy(records = records(it)) } ?: app
                })
            }
        val combined = TransitApplication.combine(snapshots) ?: return null
        val apps = combined.applications.orEmpty()
        return combined.copy(
            rawTransactions = apps.flatMap { it.records.filter { r -> r.kind == "transaction" }.map { r -> r.hex } },
            rawTransitHistory = apps.flatMap { it.records.filter { r -> r.kind == "transit" }.map { r -> r.hex } },
        )
    }

    fun records(application: Application): List<TransitApplicationRecord> =
        application.records.keys.sorted().flatMap { sfi ->
            application.records.getValue(sfi).mapIndexed { offset, data ->
                TransitApplicationRecord(if (sfi == 0x1e) "transit" else "transaction", sfi, offset + 1, data.hexString())
            }
        }

    // Backup database

    fun readCards(file: File): List<Card> {
        val db = runCatching {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
        }.getOrElse { throw NotTripReaderBackupException() }
        db.use {
            // Any other file, SQLite or not, lacks these columns.
            for ((table, columns) in requiredColumns) {
                val present = runCatching {
                    db.rawQuery("PRAGMA table_info($table)", null).use { cursor ->
                        val name = cursor.getColumnIndexOrThrow("name")
                        buildSet { while (cursor.moveToNext()) add(cursor.getString(name)) }
                    }
                }.getOrDefault(emptySet())
                if (!present.containsAll(columns)) throw NotTripReaderBackupException()
            }
            val cardRows = db.rawQuery(
                "SELECT cdRawNo, cdLastUpdate, isTU, isCU, cdBalance, cdCUBalance, cdTUBalance, cdCURawInfo, cdTURawInfo FROM card_table", null,
            ).use { c ->
                buildList {
                    while (c.moveToNext()) add(CardRow(
                        rawNumber = c.getString(0).orEmpty(), lastUpdate = if (c.isNull(1)) null else c.getLong(1),
                        isTUnion = c.getLong(2) == 1L, isCityUnion = c.getLong(3) == 1L,
                        balance = c.getLong(4), cityUnionBalance = c.getLong(5), tUnionBalance = c.getLong(6),
                        cityUnionInfo = c.getString(7), tUnionInfo = c.getString(8),
                    ))
                }
            }
            val transactionRows = db.rawQuery(
                "SELECT cdRawNo, txCUResult, txTUResult, txSFI, txCU, txCUTopUp, txCUForeign, txTU, txTU18, txTUTopUp FROM tran_table", null,
            ).use { c ->
                buildList {
                    while (c.moveToNext()) add(TransactionRow(
                        rawNumber = c.getString(0).orEmpty(), ledger = c.getString(1), travel = c.getString(2), sfi = c.getInt(3),
                        cityUnionLedger = c.getLong(4) == 1L || c.getLong(5) == 1L || c.getLong(6) == 1L,
                        tUnionLedger = c.getLong(8) == 1L || c.getLong(9) == 1L, tUnionTravel = c.getLong(7) == 1L,
                    ))
                }
            }
            return cards(cardRows, transactionRows)
        }
    }

    fun cards(cardRows: List<CardRow>, transactionRows: List<TransactionRow>): List<Card> {
        val cards = linkedMapOf<String, Card>()
        for (row in cardRows) {
            if (row.rawNumber.isEmpty()) continue
            fun balance(value: Long) = value.takeIf { it != UNKNOWN_BALANCE }
            // A dual card stores each application's balance separately and their sum in
            // cdBalance. Without a separate reading, cdBalance is the last application read.
            val separate = row.isTUnion && row.isCityUnion && balance(row.tUnionBalance) != null
            val applications = buildMap<String, Application> {
                if (row.isCityUnion) put(CITY_UNION_AID, Application(bytes(row.cityUnionInfo),
                    if (separate) balance(row.cityUnionBalance) else if (row.isTUnion) null else balance(row.balance)))
                if (row.isTUnion) put(T_UNION_AID, Application(bytes(row.tUnionInfo),
                    if (separate) balance(row.tUnionBalance) else balance(row.balance)))
            }
            val lastUpdate = row.lastUpdate?.let(Instant::fromEpochMilliseconds) ?: Clock.System.now()
            cards[row.rawNumber] = Card(row.rawNumber, lastUpdate, applications)
        }

        val collected = mutableMapOf<String, MutableMap<String, MutableMap<Int, MutableList<ByteArray>>>>()
        for (row in transactionRows) {
            val card = cards[row.rawNumber] ?: continue
            fun add(aid: String, sfi: Int, data: ByteArray) {
                collected.getOrPut(row.rawNumber) { mutableMapOf() }.getOrPut(aid) { mutableMapOf() }
                    .getOrPut(sfi) { mutableListOf() }.add(data)
            }
            // Trip Reader reads City Union before T-Union and keeps the first copy of a
            // record both applications mirror, so City Union owns a dual-flagged row.
            val ledgerAid = if (row.cityUnionLedger) CITY_UNION_AID else if (row.tUnionLedger) T_UNION_AID else null
            val ledger = bytes(row.ledger)
            if (ledgerAid != null && ledgerAid in card.applications && ledger != null && ledger.size >= 23) {
                add(ledgerAid, row.sfi.takeIf { it in 1..30 } ?: 0x18, ledger.copyOf(23))
            }
            val travel = bytes(row.travel)
            if (row.tUnionTravel && T_UNION_AID in card.applications && travel != null && travel.size >= 48) {
                add(T_UNION_AID, 0x1e, travel.copyOf(48))
            }
        }
        return cards.values.map { card ->
            val files = collected[card.rawNumber] ?: return@map card
            card.copy(applications = card.applications.mapValues { (aid, app) ->
                files[aid]?.let { Application(app.file15, app.balanceCents, it.mapValues { (_, records) -> newestFirst(records) }) } ?: app
            })
        }
    }

    /** Most recent first by the record's own BCD timestamp, then transaction counter. */
    private fun newestFirst(records: List<ByteArray>): List<ByteArray> {
        fun key(record: ByteArray) = if (record.size == 48) record.copyOfRange(25, 32).hexString()
            else record.copyOfRange(16, 23).hexString() + record.copyOfRange(0, 2).hexString()
        return records.distinctBy { it.hexString() }.sortedByDescending(::key)
    }

    private fun bytes(hex: String?): ByteArray? = hex?.hexToBytes()?.takeIf { data -> data.any { it != 0.toByte() } }

    /**
     * Answers the reader's read-only commands from the backed-up files. Unavailable
     * files return the card's not-found status, as on a partial physical read.
     */
    internal class ReplayCard(private val applications: Map<String, Application>) {
        private var selectedAid: String? = null

        fun exchange(apdu: ByteArray): ByteArray {
            if (apdu.size < 4) return "6700".hexToBytes()
            val (cla, ins, p1, p2) = apdu.take(4).map { it.toInt() and 0xff }
            val selected = selectedAid?.let(applications::get)
            val success = "9000".hexToBytes()
            val notFound = "6A82".hexToBytes()
            return when {
                cla == 0 && ins == 0xa4 -> {
                    // Only applications were backed up. A failed SELECT keeps the current one.
                    val length = apdu.getOrNull(4)?.toInt()?.and(0xff) ?: 0
                    val aid = apdu.copyOfRange(minOf(5, apdu.size), minOf(5 + length, apdu.size)).hexString()
                    if (p1 != 4 || aid !in applications) notFound else success.also { selectedAid = aid }
                }
                cla == 0 && ins == 0xb0 -> selected?.file15?.takeIf { p1 == 0x95 }?.plus(success) ?: notFound
                cla == 0 && ins == 0xb2 -> selected?.records?.get(p2 shr 3)?.getOrNull(p1 - 1)
                    ?.takeIf { p2 and 7 == 4 }?.plus(success) ?: "6A83".hexToBytes()
                cla == 0x80 && ins == 0x5c -> {
                    // P1 0 is the purse; T-Union reports overdraft debt at P1 1.
                    val cents = selected?.balanceCents
                    val isTUnion = selectedAid == T_UNION_AID
                    val value = when {
                        cents == null || p2 != 2 || apdu.size != 5 || apdu[4] != 4.toByte() -> null
                        p1 == 0 && (cents >= 0 || isTUnion) -> maxOf(cents, 0)
                        p1 == 1 && isTUnion -> maxOf(-cents, 0)
                        else -> null
                    }
                    value?.let { byteArrayOf((it shr 24).toByte(), (it shr 16).toByte(), (it shr 8).toByte(), it.toByte()) + success } ?: notFound
                }
                else -> "6D00".hexToBytes()
            }
        }
    }
}
