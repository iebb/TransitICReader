package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import ad.neko.cardbal.android.data.TransitCardSnapshot
import kotlinx.datetime.Clock

interface TransitCardDecoder {
    fun canDecode(tag: Tag): Boolean
    fun decode(tag: Tag, scannedAt: kotlinx.datetime.Instant = Clock.System.now()): TransitCardSnapshot?
}
