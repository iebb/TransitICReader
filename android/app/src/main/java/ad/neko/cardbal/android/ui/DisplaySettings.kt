package ad.neko.cardbal.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.datetime.Instant
import kotlinx.datetime.toJavaInstant

/** The iOS Display and serial-number privacy settings, with the same keys and defaults. */
object DisplaySettings {
    const val PREFERENCES = "display"
    val dateFormats = listOf(
        "yyyy-MM-dd" to "YYYY-MM-DD",
        "dd/MM/yyyy" to "DD/MM/YYYY",
        "MM/dd/yyyy" to "MM/DD/YYYY",
        "MMM d, yyyy" to "Abbreviated",
    )

    private var preferences: SharedPreferences? = null
    var dateFormat by mutableStateOf("yyyy-MM-dd")
        private set
    var usesIssuerTimeZone by mutableStateOf(true)
        private set
    var serialNumberMode by mutableIntStateOf(0)
        private set

    fun load(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        preferences = prefs
        dateFormat = prefs.getString("dateFormat", null)?.takeIf { format -> dateFormats.any { it.first == format } } ?: "yyyy-MM-dd"
        usesIssuerTimeZone = prefs.getString("cardTimeZonePreference", "issuer") != "current"
        serialNumberMode = prefs.getInt("snDisplayMode", 0).coerceIn(0, 2)
    }

    fun updateDateFormat(format: String) {
        dateFormat = format
        preferences?.edit()?.putString("dateFormat", format)?.apply()
    }

    fun updateUsesIssuerTimeZone(issuer: Boolean) {
        usesIssuerTimeZone = issuer
        preferences?.edit()?.putString("cardTimeZonePreference", if (issuer) "issuer" else "current")?.apply()
    }

    fun updateSerialNumberMode(mode: Int) {
        serialNumberMode = mode
        preferences?.edit()?.putInt("snDisplayMode", mode)?.apply()
    }

    fun formatDateTime(instant: Instant, issuerTimeZone: String?, locale: Locale = Locale.getDefault()): String {
        val zone = issuerTimeZone?.takeIf { usesIssuerTimeZone }?.let { runCatching { ZoneId.of(it) }.getOrNull() }
            ?: ZoneId.systemDefault()
        val separator = if ('/' in dateFormat || '-' in dateFormat) " " else ", "
        return DateTimeFormatter.ofPattern("$dateFormat${separator}HH:mm", locale).withZone(zone).format(instant.toJavaInstant())
    }
}
