package ad.neko.cardbal.android.nfc

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import androidx.lifecycle.ViewModel
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.data.ClipperTransitCatalog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.datetime.Clock

class CardBalNfcReader : ViewModel(), NfcAdapter.ReaderCallback {
    private var clipperLookup: ClipperLookup = ClipperLookup.Numeric
    private var octopusStore: OctopusMetadataStore? = null
    private val decoders: List<TransitCardDecoder> get() = orderedDecoders(clipperLookup, octopusStore)
    private val _latestSnapshot = MutableStateFlow<TransitCardSnapshot?>(null)
    private val _status = MutableStateFlow("Ready to scan.")
    private val _isScanning = MutableStateFlow(false)
    private var readerModeEnabled = false

    val latestSnapshot: StateFlow<TransitCardSnapshot?> = _latestSnapshot
    val status: StateFlow<String> = _status
    val isScanning: StateFlow<Boolean> = _isScanning

    fun start(activity: Activity) {
        clipperLookup = ClipperTransitCatalog.get(activity)
        octopusStore = OctopusMetadataStore(activity.applicationContext.getSharedPreferences(OctopusMetadataStore.PREFERENCES, 0))
        val adapter = NfcAdapter.getDefaultAdapter(activity)
        if (adapter == null || !adapter.isEnabled) {
            _status.value = "NFC is not available."
            _isScanning.value = false
            readerModeEnabled = false
            return
        }
        _isScanning.value = true
        if (!readerModeEnabled) {
            _status.value = "Ready for NFC."
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
        val scannedAt=Clock.System.now()
        val results=read(decoders) { decoder ->
            if(decoder.canDecode(tag)) runCatching { decoder.decode(tag,scannedAt) }.getOrNull() else null
        }
        val snapshot=TransitApplication.combine(results)
        if (snapshot == null) {
            _status.value = "Unsupported card type."
        } else {
            _latestSnapshot.value = snapshot
            _status.value = "Read successful: ${snapshot.cardFamily}"
        }
        _isScanning.value = readerModeEnabled
    }

    internal companion object {
        // City Union / T-Union (Iso7816Decoder) are read before the local reader, whose
        // SELECTs ran first in 2.6.0 and left City Union-only cards unreadable.
        internal fun orderedDecoders(clipperLookup: ClipperLookup, octopusStore: OctopusMetadataStore?): List<TransitCardDecoder> = listOf(
            CEPASDecoder(), MacauPassDecoder(), ClipperDecoder(clipperLookup), ClipperUltralightDecoder(clipperLookup),
            StoredValueDecoder(), CalypsoDecoder(), Iso7816Decoder(), ChineseLocalDecoder(), JapaneseICDecoder(octopusStore),
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
