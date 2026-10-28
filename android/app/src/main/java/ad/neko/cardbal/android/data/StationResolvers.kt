package ad.neko.cardbal.android.data

import android.content.Context

class StationResolver private constructor(context: Context) {
    private val stations: Map<String, String> = context.assets.open("JPStationCodes.csv").bufferedReader().useLines { lines ->
        lines.mapNotNull { line ->
            val parts = line.split(",")
            if (parts.size >= 2) parts[0].trim().uppercase() to parts[1].trim() else null
        }.toMap()
    }

    fun resolve(code: Int): String? = stations["%05X".format(code)]

    companion object {
        @Volatile private var instance: StationResolver? = null
        fun get(context: Context): StationResolver = instance ?: synchronized(this) {
            instance ?: StationResolver(context.applicationContext).also { instance = it }
        }
    }
}

class BusResolver private constructor(context: Context) {
    private val buses: Map<Int, String> = context.assets.open("JPBusCodes.csv").bufferedReader().useLines { lines ->
        lines.mapNotNull { line ->
            val parts = line.split(",")
            val code = parts.firstOrNull()?.trim()?.toIntOrNull(16)
            if (parts.size >= 2 && code != null) code to parts[1].trim() else null
        }.toMap()
    }

    fun resolve(code: Int): String? = buses[code]

    companion object {
        @Volatile private var instance: BusResolver? = null
        fun get(context: Context): BusResolver = instance ?: synchronized(this) {
            instance ?: BusResolver(context.applicationContext).also { instance = it }
        }
    }
}
