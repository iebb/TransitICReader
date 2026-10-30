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
    private val unifiedDb by lazy { openAssetDatabase("cardbal_transit.sqlite") }
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

    private val japaneseGraph by lazy {
        val graph=mutableMapOf<String,MutableList<TransitGeometry.Edge>>()
        unifiedDb.rawQuery("SELECT e.from_station_code,e.to_station_code,e.distance_km,p.geohash_path FROM station_graph_edges e LEFT JOIN station_edge_paths p USING(country_code,line_code,from_station_code,to_station_code) WHERE e.country_code='JP'",emptyArray()).use { c ->
            while(c.moveToNext()) {
                val from=c.getString(0);val to=c.getString(1);val distance=c.getDouble(2);val packed=c.getString(3)
                graph.getOrPut(from){mutableListOf()}.add(TransitGeometry.Edge(to,distance,packed))
                graph.getOrPut(to){mutableListOf()}.add(TransitGeometry.Edge(from,distance,packed,true))
            }
        }
        graph
    }

    fun shortestJapanesePath(from: StationPoint, to: StationPoint): List<StationPoint> {
        if(from.stationCode==to.stationCode) return listOf(from)
        val steps=TransitGeometry.shortest(from.stationCode,to.stationCode,japaneseGraph) ?: return listOf(from,to)
        val result=mutableListOf(from)
        for((_,edge) in steps) {
            val points=edge.packed?.let(TransitGeometry::decodePath)?.let{if(edge.reversed) it.reversed() else it}
            if(points!=null) result+=points.mapIndexed { i,p -> StationPoint("geometry:${edge.to}:$i","", "",p.latitude,p.longitude) }
            else findJapaneseStationByStationCode(edge.to)?.let(result::add)
        }
        result.add(to)
        return result
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

    fun locationName(namespace: String, code: String, event: Int? = null): String? {
        val kind = if (event == 0) "entry" else if (event == 1) "exit" else "any"
        unifiedDb.rawQuery("SELECT COALESCE(i.lookup_name,s.name) FROM station_identifiers i JOIN stations s ON s.id=i.station_id WHERE i.namespace=? AND i.code=? AND i.event_kind IN ('any',?) ORDER BY i.event_kind='any' LIMIT 1", arrayOf(namespace,code.uppercase(),kind)).use {
            return if(it.moveToFirst()) it.getString(0) else null
        }
    }

    fun findCatalogStation(namespace: String, code: String?, event: Int? = null): StationPoint? {
        if(code==null) return null
        val kind=if(event==0) "entry" else if(event==1) "exit" else "any"
        unifiedDb.rawQuery("SELECT i.code,s.id,COALESCE(i.lookup_name,s.name),s.latitude,s.longitude FROM station_identifiers i JOIN stations s ON s.id=i.station_id WHERE i.namespace=? AND i.code=? AND i.event_kind IN ('any',?) AND s.latitude IS NOT NULL AND s.longitude IS NOT NULL ORDER BY i.event_kind='any' LIMIT 1",arrayOf(namespace,code.uppercase(),kind)).use {
            return if(it.moveToFirst()) StationPoint(it.getString(0),it.getString(1),it.getString(2),it.getDouble(3),it.getDouble(4)) else null
        }
    }

    data class ChineseLocation(val name:String,val key:String?,val type:String?)
    fun tUnionLocation(code:String):ChineseLocation? {
        val normalized=normalizeCode(code) ?: return null
        tUnionDb.rawQuery("SELECT COALESCE(display_name,station_name),station_key,source_type FROM tunion_stations WHERE station_key=? OR ? LIKE station_key || '%' ORDER BY length(station_key) DESC LIMIT 1",arrayOf(normalized,normalized)).use {
            return if(it.moveToFirst()) ChineseLocation(it.getString(0),it.getString(1),it.getString(2)) else null
        }
    }
    fun tUnionTerminal(kind:String,terminal:String,city:String?=null):ChineseLocation? {
        if(kind=="1e" && city==null) return null
        val rows=mutableListOf<ChineseLocation>()
        val sql="SELECT station_name,station_key,station_type FROM tunion_terminal_stations WHERE record_kind=? AND terminal_code=?"+(if(city!=null) " AND city_id=?" else "")
        val args=if(city!=null) arrayOf(kind,terminal,city) else arrayOf(kind,terminal)
        unifiedDb.rawQuery(sql,args).use { c -> while(c.moveToNext()) rows.add(ChineseLocation(c.getString(0),c.getString(1),c.getString(2))) }
        return rows.distinct().singleOrNull()
    }

    fun cityUnionTerminal(terminal: String, date: kotlinx.datetime.Instant?): ChineseLocation? {
        if(terminal.length!=12 || !terminal.startsWith("2000") || date==null || date.epochSeconds<1483200000) return null
        unifiedDb.rawQuery("SELECT station_name,station_key,station_type FROM cityunion_terminal_prefixes WHERE ? LIKE terminal_prefix || '%' ORDER BY length(terminal_prefix) DESC LIMIT 1",arrayOf(terminal)).use {
            return if(it.moveToFirst()) ChineseLocation(it.getString(0),it.getString(1),it.getString(2)) else null
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
