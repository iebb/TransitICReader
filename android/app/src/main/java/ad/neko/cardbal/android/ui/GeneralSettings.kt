package ad.neko.cardbal.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ad.neko.cardbal.android.nfc.DeveloperModePreferences

/** The iOS Scan on Launch and Developer Mode settings, with the same keys and defaults. */
object GeneralSettings {
    private const val SCAN_ON_LAUNCH_KEY = "scanOnLaunch"

    private var preferences: SharedPreferences? = null
    var scanOnLaunch by mutableStateOf(true)
        private set
    var developerModeEnabled by mutableStateOf(false)
        private set

    fun load(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(DeveloperModePreferences.PREFERENCES, Context.MODE_PRIVATE)
        preferences = prefs
        scanOnLaunch = prefs.getBoolean(SCAN_ON_LAUNCH_KEY, true)
        developerModeEnabled = prefs.getBoolean(DeveloperModePreferences.ENABLED_KEY, false)
    }

    fun updateScanOnLaunch(enabled: Boolean) {
        scanOnLaunch = enabled
        preferences?.edit()?.putBoolean(SCAN_ON_LAUNCH_KEY, enabled)?.apply()
    }

    fun updateDeveloperMode(enabled: Boolean) {
        developerModeEnabled = enabled
        preferences?.edit()?.putBoolean(DeveloperModePreferences.ENABLED_KEY, enabled)?.apply()
    }
}
