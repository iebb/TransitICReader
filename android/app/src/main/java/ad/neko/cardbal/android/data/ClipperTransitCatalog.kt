package ad.neko.cardbal.android.data

import android.content.Context
import ad.neko.cardbal.android.nfc.ClipperLookup
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** FareBot's pinned station names, mapping IDs and original data notices. */
class ClipperTransitCatalog private constructor(private val payload: Payload?) : ClipperLookup {
    @Serializable private data class Operator(val name: String, val mode: Int)
    @Serializable private data class Station(
        val id: Int, val name: String, val latitude: Double, val longitude: Double,
    )
    @Serializable private data class Payload(
        val version: Int, val notice: String, val operators: Map<String, Operator>,
        val lines: Map<String, Operator>, val stations: Map<String, Station>,
    )

    val notice: String get() = payload?.notice.orEmpty()

    override fun agencyName(agency: Int): String =
        payload?.operators?.get(agency.toString())?.name ?: super.agencyName(agency)

    override fun defaultMode(agency: Int): Int = payload?.operators?.get(agency.toString())?.mode ?: 0

    override fun stationCode(agency: Int, station: Int): String? =
        payload?.stations?.get(((agency shl 16) or station).toString())?.let { "CLIPPER:${it.id}" }

    override fun stationName(agency: Int, station: Int, isEnd: Boolean): String? =
        payload?.stations?.get(((agency shl 16) or station).toString())?.name
            ?: super.stationName(agency, station, isEnd)

    override fun routeName(agency: Int, route: Int): String? =
        payload?.lines?.get(((agency shl 16) or route).toString())?.name ?: super.routeName(agency, route)

    fun point(code: String?): StationPoint? {
        if (code?.startsWith("CLIPPER:") != true) return null
        val station = payload?.stations?.get(code.removePrefix("CLIPPER:")) ?: return null
        if (station.latitude !in -90.0..90.0 || station.longitude !in -180.0..180.0 ||
            station.latitude == 0.0 && station.longitude == 0.0) return null
        return StationPoint(code, code, station.name, station.latitude, station.longitude)
    }

    companion object {
        @Volatile private var instance: ClipperTransitCatalog? = null
        fun get(context: Context): ClipperTransitCatalog = instance ?: synchronized(this) {
            instance ?: runCatching {
                fromJson(context.applicationContext.assets.open("ClipperTransit.json")
                    .bufferedReader().use { it.readText() })
            }.getOrElse { ClipperTransitCatalog(null) }.also { instance = it }
        }

        fun fromJson(text: String): ClipperTransitCatalog {
            val parsed = Json { ignoreUnknownKeys = true }.decodeFromString<Payload>(text)
            require(parsed.version == 1) { "Unsupported Clipper catalog version" }
            return ClipperTransitCatalog(parsed)
        }
    }
}
