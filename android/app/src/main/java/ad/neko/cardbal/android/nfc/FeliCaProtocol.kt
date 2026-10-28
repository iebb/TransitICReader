package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexToBytes
import java.io.IOException

/** NFC-F framing separated from Android so system changes can be tested synthetically. */
internal class FeliCaProtocol(
    initialIdm: ByteArray,
    private val exchange: (ByteArray) -> ByteArray,
) {
    private var currentIdm = initialIdm.copyOf().also { require(it.size == 8) }
    private var selected = false
    val idm: ByteArray get() = currentIdm.copyOf()

    fun polling(systemCodeHex: String): Boolean {
        selected = false
        val system = runCatching { systemCodeHex.hexToBytes() }.getOrNull() ?: return false
        if (system.size != 2) return false
        return try {
            val response = exchange(byteArrayOf(0x06, 0x00, system[0], system[1], 0x01, 0x00))
            // Request code 01 includes the selected system after IDm and PMm.
            if (!validFrame(response, 0x01, 20) ||
                response[18] != system[0] || response[19] != system[1]
            ) return false
            currentIdm = response.copyOfRange(2, 10)
            selected = true
            true
        } catch (_: IOException) {
            false
        }
    }

    fun requestSystemCodes(): List<String> {
        if (!selected) return emptyList()
        return try {
            val response = exchange(byteArrayOf(0x0A, 0x0C, *currentIdm))
            if (response.size < 11 || !validAddressedFrame(response, 0x0D)) return emptyList()
            val count = response[10].toInt() and 0xff
            if (response.size != 11 + count * 2) return emptyList()
            (0 until count).map { index ->
                val start = 11 + index * 2
                "%02X%02X".format(response[start], response[start + 1])
            }
        } catch (_: IOException) {
            emptyList()
        }
    }

    fun readWithoutEncryption(serviceCodeLittleEndianHex: String, blockIndex: Int): ByteArray? {
        if (!selected || blockIndex !in 0..255) return null
        val service = runCatching { serviceCodeLittleEndianHex.hexToBytes() }.getOrNull() ?: return null
        if (service.size != 2) return null
        val command = byteArrayOf(
            0x10, 0x06, *currentIdm, 0x01, service[0], service[1],
            0x01, 0x80.toByte(), blockIndex.toByte(),
        )
        return try {
            val response = exchange(command)
            if (!validAddressedFrame(response, 0x07) || response.size != 29 ||
                response[10] != 0.toByte() || response[11] != 0.toByte() ||
                response[12] != 1.toByte()
            ) null else response.copyOfRange(13, 29)
        } catch (_: IOException) {
            null
        }
    }

    private fun validAddressedFrame(response: ByteArray, command: Int): Boolean =
        response.size >= 10 && validFrame(response, command, response.size) &&
            response.copyOfRange(2, 10).contentEquals(currentIdm)

    private fun validFrame(response: ByteArray, command: Int, size: Int): Boolean =
        response.size == size && size >= 2 && (response[0].toInt() and 0xff) == size &&
            (response[1].toInt() and 0xff) == command
}
