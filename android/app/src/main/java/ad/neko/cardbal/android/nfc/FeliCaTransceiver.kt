package ad.neko.cardbal.android.nfc

import android.nfc.tech.NfcF
import ad.neko.cardbal.android.util.hexString

class FeliCaTransceiver(private val nfc: NfcF) : AutoCloseable {
    internal val protocol = FeliCaProtocol(nfc.tag.id) { nfc.transceive(it) }
    val idm: ByteArray get() = protocol.idm
    val idmHex: String get() = idm.hexString()

    fun connect() {
        if (!nfc.isConnected) nfc.connect()
        nfc.timeout = 1500
    }

    fun requestSystemCodes(): List<String> = protocol.requestSystemCodes()

    fun polling(systemCodeHex: String): Boolean = protocol.polling(systemCodeHex)

    fun readWithoutEncryption(serviceCodeLittleEndianHex: String, blockIndex: Int): ByteArray? =
        protocol.readWithoutEncryption(serviceCodeLittleEndianHex, blockIndex)

    internal fun exchangeOnline(command: ByteArray): ByteArray = protocol.exchangeOnline(command)

    override fun close() {
        runCatching { nfc.close() }
    }
}
