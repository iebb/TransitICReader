package ad.neko.cardbal.android.data

internal object ChineseCityCodes {
    fun cityUnionName(code: String): String? = when (code) {
        "2000", "上海市" -> "上海市"
        "5180", "深圳市" -> "深圳市"
        else -> null
    }

    fun shenzhenTravelTerminal(city: String, terminal: String): String? {
        val normalized = terminal.uppercase()
        if (city != "5840" || normalized.length != 16 || !normalized.startsWith("00000002") ||
            normalized.any { it !in "0123456789ABCDEF" }) return null
        return "5180" + normalized.takeLast(8)
    }
}
