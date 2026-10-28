package ad.neko.cardbal.android.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File

data class StationPoint(
    val code: String,
    val stationCode: String,
    val name: String,
    val latitude: Double,
    val longitude: Double,
)

class StationDatabase private constructor(private val context: Context) {
    private val jpDb by lazy { openAssetDatabase("jp_stations.sqlite") }
    private val tUnionDb by lazy { openAssetDatabase("tunion_stations.sqlite") }

    fun findJapaneseStation(code: String?): StationPoint? {
        val normalized = normalizeCode(code) ?: return null
        jpDb.rawQuery(
            """
            SELECT hex_code, station_code, station_name, latitude, longitude
            FROM jp_stations
            WHERE (hex_code = ? OR code_integer = ?)
              AND is_pseudo = 0
              AND station_code != '0'
            LIMIT 1
            """.trimIndent(),
            arrayOf(normalized, normalized.toIntOrNull(16)?.toString() ?: "-1"),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return StationPoint(
                code = cursor.getString(0),
                stationCode = cursor.getString(1),
                name = cursor.getString(2),
                latitude = cursor.getDouble(3),
                longitude = cursor.getDouble(4),
            )
        }
    }

    fun shortestJapanesePath(from: StationPoint, to: StationPoint): List<StationPoint> {
        if (from.stationCode == to.stationCode) return listOf(from)
        val start = from.stationCode
        val target = to.stationCode
        val adjacency = mutableMapOf<String, MutableList<String>>()
        jpDb.rawQuery(
            """
            SELECT from_station_code, to_station_code
            FROM station_edges
            WHERE from_station_code != '0' AND to_station_code != '0'
            """.trimIndent(),
            emptyArray(),
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val a = cursor.getString(0)
                val b = cursor.getString(1)
                adjacency.getOrPut(a) { mutableListOf() }.add(b)
                adjacency.getOrPut(b) { mutableListOf() }.add(a)
            }
        }

        val queue = ArrayDeque<String>()
        val previous = mutableMapOf<String, String?>()
        queue.add(start)
        previous[start] = null
        while (queue.isNotEmpty()) {
            val current = queue.removeFirst()
            if (current == target) break
            for (next in adjacency[current].orEmpty()) {
                if (previous.containsKey(next)) continue
                previous[next] = current
                queue.add(next)
            }
        }
        if (!previous.containsKey(target)) return listOf(from, to)

        val stationCodes = mutableListOf<String>()
        var cursor: String? = target
        while (cursor != null) {
            stationCodes.add(cursor)
            cursor = previous[cursor]
        }
        stationCodes.reverse()
        return stationCodes.mapNotNull(::findJapaneseStationByStationCode).ifEmpty { listOf(from, to) }
    }

    fun findTUnionStation(code: String?): StationPoint? {
        val normalized = normalizeCode(code) ?: return null
        tUnionDb.rawQuery(
            """
            SELECT station_key, COALESCE(display_name, station_name), latitude, longitude
            FROM tunion_stations
            WHERE (source_code = ? OR station_key = ?)
              AND latitude IS NOT NULL AND longitude IS NOT NULL
            LIMIT 1
            """.trimIndent(),
            arrayOf(normalized, normalized),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return StationPoint(
                code = cursor.getString(0),
                stationCode = cursor.getString(0),
                name = cursor.getString(1),
                latitude = cursor.getDouble(2),
                longitude = cursor.getDouble(3),
            )
        }

        tUnionDb.rawQuery(
            """
            SELECT station_key, COALESCE(display_name, station_name), latitude, longitude
            FROM tunion_stations
            WHERE ? LIKE station_key || '%'
              AND latitude IS NOT NULL AND longitude IS NOT NULL
            ORDER BY length(station_key) DESC
            LIMIT 1
            """.trimIndent(),
            arrayOf(normalized),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return StationPoint(
                code = cursor.getString(0),
                stationCode = cursor.getString(0),
                name = cursor.getString(1),
                latitude = cursor.getDouble(2),
                longitude = cursor.getDouble(3),
            )
        }
    }

    private fun findJapaneseStationByStationCode(stationCode: String): StationPoint? {
        jpDb.rawQuery(
            """
            SELECT hex_code, station_code, station_name, latitude, longitude
            FROM jp_stations
            WHERE station_code = ?
              AND is_pseudo = 0
              AND station_code != '0'
            LIMIT 1
            """.trimIndent(),
            arrayOf(stationCode),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return StationPoint(
                code = cursor.getString(0),
                stationCode = cursor.getString(1),
                name = cursor.getString(2),
                latitude = cursor.getDouble(3),
                longitude = cursor.getDouble(4),
            )
        }
    }

    private fun normalizeCode(code: String?): String? {
        val clean = code?.uppercase()?.removePrefix("0X")?.filter { it.isLetterOrDigit() }.orEmpty()
        return clean.ifBlank { null }
    }

    private fun openAssetDatabase(assetName: String): SQLiteDatabase {
        val file = File(context.filesDir, "assets-db/$assetName")
        file.parentFile?.mkdirs()
        context.assets.open(assetName).use { input ->
            file.outputStream().use { output -> input.copyTo(output) }
        }
        return SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
    }

    companion object {
        @Volatile private var instance: StationDatabase? = null
        fun get(context: Context): StationDatabase = instance ?: synchronized(this) {
            instance ?: StationDatabase(context.applicationContext).also { instance = it }
        }
    }
}
