package ad.neko.cardbal.android.nfc

import android.app.Activity
import android.content.SharedPreferences
import android.nfc.NfcAdapter
import android.nfc.Tag
import androidx.lifecycle.ViewModel
import ad.neko.cardbal.android.data.DebugLog
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.data.ClipperTransitCatalog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.datetime.Clock

/** The iOS Developer Mode setting, with the same key and default. */
object DeveloperModePreferences {
    const val PREFERENCES = "general"
    const val ENABLED_KEY = "developerModeEnabled"
}

class CardBalNfcReader : ViewModel(), NfcAdapter.ReaderCallback {
    private var clipperLookup: ClipperLookup = ClipperLookup.Numeric
    private var octopusStore: OctopusMetadataStore? = null
    private var generalPreferences: SharedPreferences? = null
    private var madridPreferences: SharedPreferences? = null
    private val decoders: List<TransitCardDecoder>
        get() = orderedDecoders(clipperLookup, octopusStore,
            developerMode = generalPreferences?.getBoolean(DeveloperModePreferences.ENABLED_KEY, false) == true,
            madridPreferences = madridPreferences)
    private val _latestSnapshot = MutableStateFlow<TransitCardSnapshot?>(null)
    private val _status = MutableStateFlow("Ready to scan.")
    private val _isScanning = MutableStateFlow(false)
    private var readerModeEnabled = false

    val latestSnapshot: StateFlow<TransitCardSnapshot?> = _latestSnapshot
    val status: StateFlow<String> = _status
    val isScanning: StateFlow<Boolean> = _isScanning
    /** Set once scanning has started, so returning to the app resumes it even when Scan on Launch is off. */
    var hasStarted = false
        private set

    fun start(activity: Activity) {
        clipperLookup = ClipperTransitCatalog.get(activity)
        octopusStore = OctopusMetadataStore(activity.applicationContext.getSharedPreferences(OctopusMetadataStore.PREFERENCES, 0))
        generalPreferences = activity.applicationContext.getSharedPreferences(DeveloperModePreferences.PREFERENCES, 0)
        madridPreferences = activity.applicationContext.getSharedPreferences(MadridTtpPreferences.PREFERENCES, 0)
        val adapter = NfcAdapter.getDefaultAdapter(activity)
        if (adapter == null || !adapter.isEnabled) {
            if (_status.value != "NFC is not available.") DebugLog.log("Scan", "Scan not started: NFC reading is not available")
            _status.value = "NFC is not available."
            _isScanning.value = false
            readerModeEnabled = false
            return
        }
        _isScanning.value = true
        hasStarted = true
        if (!readerModeEnabled) {
            _status.value = "Ready for NFC."
            DebugLog.log("Scan", "Reader mode on")
        }
        adapter.enableReaderMode(
            activity,
            this,
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_NFC_F or
                NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
            null,
        )
        readerModeEnabled = true
    }

    fun stop(activity: Activity) {
        NfcAdapter.getDefaultAdapter(activity)?.disableReaderMode(activity)
        _isScanning.value = false
        readerModeEnabled = false
        _status.value = "Ready to scan."
    }

    override fun onTagDiscovered(tag: Tag) {
        _status.value = "Reading card..."
        DebugLog.log("Scan", "Tag detected: ${tag.techList.joinToString(", ") { it.substringAfterLast('.') }}, UID ${DebugLog.shortened(tag.id ?: ByteArray(0))}")
        val scannedAt=Clock.System.now()
        val declined=mutableListOf<String>()
        val results=read(decoders) { decoder ->
            val name=decoder.javaClass.simpleName
            if(!decoder.canDecode(tag)) return@read null
            runCatching { decoder.decode(tag,scannedAt) }
                .onSuccess { snapshot -> if(snapshot==null) declined.add(name) else DebugLog.log("Scan", "$name: read ${snapshot.cardFamily}") }
                .onFailure { DebugLog.log("Scan", "$name: " + DebugLog.describe(it)) }
                .getOrNull()
        }
        if(declined.isNotEmpty()) DebugLog.log("Scan", "Not for this tag: " + declined.joinToString(", "))
        val snapshot=TransitApplication.combine(results)
        if (snapshot == null) {
            _status.value = "Unsupported card type."
            DebugLog.log("Scan", "Failed: Unsupported card type.")
        } else {
            _latestSnapshot.value = snapshot
            _status.value = "Read successful: ${snapshot.cardFamily}"
            DebugLog.log("Scan", "Finished: ${snapshot.cardFamily}, ${snapshot.applications.orEmpty().size.coerceAtLeast(1)} application(s), " +
                "${snapshot.rawTransactions.size} transactions, ${snapshot.rawTransitHistory.size} trips")
        }
        _isScanning.value = readerModeEnabled
    }

    internal companion object {
        // City Union / T-Union (Iso7816Decoder) are read before the local reader, whose
        // SELECTs ran first in 2.6.0 and left City Union-only cards unreadable.
        // Madrid cards are read online, after the public DESFire layouts.
        internal fun orderedDecoders(clipperLookup: ClipperLookup, octopusStore: OctopusMetadataStore?, developerMode: Boolean = false,
                                     madridPreferences: SharedPreferences? = null): List<TransitCardDecoder> = listOf(
            CEPASDecoder(), MacauPassDecoder(), ClipperDecoder(clipperLookup), ClipperUltralightDecoder(clipperLookup),
            StoredValueDecoder(), MadridTtpDecoder(madridPreferences), CalypsoDecoder(), Iso7816Decoder(developerMode), ChineseLocalDecoder(), JapaneseICDecoder(octopusStore),
        )

        /** Reads in order until one decoder succeeds. After a City Union / T-Union read, the local
         *  application and the Octopus side of the same card are still read as extra applications. */
        internal fun read(decoders: List<TransitCardDecoder>, attempt: (TransitCardDecoder) -> TransitCardSnapshot?): List<TransitCardSnapshot> {
            val results=mutableListOf<TransitCardSnapshot>()
            for(decoder in decoders) {
                if(results.isNotEmpty()) {
                    // Lingnan Pass pairs like T-Union: older 岭南通·八达通 cards carry it beside Octopus.
                    val mainland=results.any { s -> s.applications.orEmpty().any { it.isTUnion || it.isCityUnion || it.isLingnan } }
                    val macau=results.any { s -> s.applications.orEmpty().any { it.isMacauPass } }
                    if(!mainland || macau || (decoder !is JapaneseICDecoder && decoder !is ChineseLocalDecoder)) continue
                }
                attempt(decoder)?.let(results::add)
            }
            return results
        }
    }
}
