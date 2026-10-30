package ad.neko.cardbal.android.nfc

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import androidx.lifecycle.ViewModel
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.data.TransitApplication
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.datetime.Clock

class CardBalNfcReader : ViewModel(), NfcAdapter.ReaderCallback {
    private val decoders: List<TransitCardDecoder> = listOf(CEPASDecoder(), StoredValueDecoder(), CalypsoDecoder(), Iso7816Decoder(), JapaneseICDecoder())
    private val _latestSnapshot = MutableStateFlow<TransitCardSnapshot?>(null)
    private val _status = MutableStateFlow("Ready to scan.")
    private val _isScanning = MutableStateFlow(false)
    private var readerModeEnabled = false

    val latestSnapshot: StateFlow<TransitCardSnapshot?> = _latestSnapshot
    val status: StateFlow<String> = _status
    val isScanning: StateFlow<Boolean> = _isScanning

    fun start(activity: Activity) {
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
        val results=mutableListOf<TransitCardSnapshot>()
        for(decoder in decoders) {
            if(results.isNotEmpty()) {
                val mainland=results.any { s -> s.applications.orEmpty().any { it.isTUnion || it.isCityUnion } }
                if(!mainland || decoder !is JapaneseICDecoder) continue
            }
            if(decoder.canDecode(tag)) runCatching { decoder.decode(tag,scannedAt) }.getOrNull()?.let(results::add)
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
}
