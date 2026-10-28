package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes

/** Read-only commands for the already supported applications; no issuer keys are used. */
internal object Iso7816Protocol {
    const val CONFIGURATION_AID = "A0000004520001"

    data class Application(val aid: String, val family: String, val currency: String)
    data class Selection(
        val application: Application,
        val response: ByteArray,
        val configurationResponse: ByteArray? = null,
    )

    val applications = listOf(
        Application("D4100000030001", "T-money", "KRW"),
        Application("D4100000140001", "EZL / Cashbee", "KRW"),
        Application("D410000029000001", "NAMANE", "KRW"),
        Application("A000000632010105", "China T-Union", "CNY"),
    )
    val selectionAids = applications.map { it.aid } + CONFIGURATION_AID

    fun select(aid: String, exchange: (ByteArray) -> ByteArray): Selection? {
        val response = exchange(selectCommand(aid))
        if (!response.isSuccess) return null
        applications.firstOrNull { it.aid == aid }?.let { return Selection(it, response) }
        if (aid != CONFIGURATION_AID) return null

        // KROCAP's configuration DF is not a transit product. Only follow an
        // unambiguous, supported Korean main-application AID from its FCI.
        val mainAid = configuredApplicationAid(response.dropLast(2).toByteArray()) ?: return null
        val application = applications.firstOrNull { it.aid == mainAid && it.currency == "KRW" }
            ?: return null
        val mainResponse = exchange(selectCommand(mainAid))
        return if (mainResponse.isSuccess) Selection(application, mainResponse, response) else null
    }

    fun selectCommand(aid: String): ByteArray {
        val bytes = aid.hexToBytes()
        return byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, bytes.size.toByte(), *bytes, 0x00)
    }

    fun balanceCommand(application: Application): ByteArray =
        if (application.currency == "CNY") "805C000204".hexToBytes()
        else "904C000004".hexToBytes()

    fun balanceValue(response: ByteArray): Long? {
        if (!response.isSuccess || response.size != 6) return null
        return response.take(4).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 0xff) }
    }

    fun configuredApplicationAid(fci: ByteArray): String? {
        val values = mutableSetOf<String>()
        fun read(start: Int, end: Int, depth: Int): Boolean {
            if (depth > 8) return false
            var position = start
            while (position < end) {
                val firstTag = fci[position++].toInt() and 0xff
                if ((firstTag and 0x1f) == 0x1f) {
                    var tagBytes = 1
                    do {
                        if (position >= end || ++tagBytes > 4) return false
                        val next = fci[position++].toInt() and 0xff
                    } while ((next and 0x80) != 0)
                }
                if (position >= end) return false
                val firstLength = fci[position++].toInt() and 0xff
                val length = if (firstLength < 0x80) firstLength else {
                    val count = firstLength and 0x7f
                    if (count !in 1..3 || count > end - position) return false
                    var value = 0
                    repeat(count) { value = (value shl 8) or (fci[position++].toInt() and 0xff) }
                    value
                }
                if (length > end - position) return false
                val next = position + length
                if (firstTag == 0x4f) values.add(fci.copyOfRange(position, next).hexString())
                if ((firstTag and 0x20) != 0 && !read(position, next, depth + 1)) return false
                position = next
            }
            return true
        }
        return if (read(0, fci.size, 0)) values.singleOrNull() else null
    }
}

internal val ByteArray.isSuccess: Boolean
    get() = size >= 2 && this[size - 2] == 0x90.toByte() && this[size - 1] == 0x00.toByte()
