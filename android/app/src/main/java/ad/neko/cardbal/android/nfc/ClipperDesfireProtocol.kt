package ad.neko.cardbal.android.nfc

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InterruptedIOException

/** Wrapped, plain DESFire reads for the older Clipper layout. No authentication or writes. */
internal class ClipperDesfireProtocol(private val exchange: (ByteArray) -> ByteArray) {
    class ReadException(val status: Int? = null, message: String = "Invalid Clipper DESFire response") :
        IOException(message)

    fun select(application: ByteArray) {
        if (application.size != 3) throw ReadException()
        if (command(0x5A, application).isNotEmpty()) throw ReadException()
    }

    fun readFile(number: Int): ByteArray {
        if (number !in 0..255) throw ReadException()
        val settings = command(0xF5, byteArrayOf(number.toByte()))
        if (settings.size < 7) throw ReadException()
        if (settings[1] != 0.toByte()) throw ReadException(message = "Protected Clipper file is unavailable")
        fun length(offset: Int): Int = (0..2).fold(0) { value, index ->
            value or ((settings[offset + index].toInt() and 255) shl (index * 8))
        }
        val instruction: Int
        val size: Int
        when (settings[0].toInt() and 255) {
            0, 1 -> {
                instruction = 0xBD
                size = length(4)
            }
            3, 4 -> {
                if (settings.size < 13 || length(4) != 32 || length(10) > length(7)) throw ReadException()
                instruction = 0xBB
                val count = length(10)
                if (count > MAXIMUM_FILE_SIZE / 32) throw ReadException()
                size = 32 * count
            }
            else -> throw ReadException(message = "Unsupported Clipper file type")
        }
        if (size > MAXIMUM_FILE_SIZE) throw ReadException()
        if (size == 0) return byteArrayOf()
        val data = command(instruction, byteArrayOf(number.toByte(), 0, 0, 0, 0, 0, 0))
        if (data.size != size) throw ReadException(message = "Incomplete Clipper file")
        return data
    }

    fun command(instruction: Int, data: ByteArray = byteArrayOf()): ByteArray {
        if (instruction !in setOf(0x5A, 0xF5, 0xBD, 0xBB, 0xAF) || data.size > 255) {
            throw ReadException(message = "Only Clipper select/settings/read commands are permitted")
        }
        var operation = instruction
        var parameters = data
        val result = ByteArrayOutputStream()
        repeat(MAXIMUM_FRAMES) {
            if (Thread.currentThread().isInterrupted) throw InterruptedIOException("Clipper read interrupted")
            val header = byteArrayOf(0x90.toByte(), operation.toByte(), 0, 0)
            val request = if (parameters.isEmpty()) header + byteArrayOf(0)
                else header + byteArrayOf(parameters.size.toByte()) + parameters + byteArrayOf(0)
            val reply = exchange(request)
            if (reply.size < 2 || reply[reply.size - 2] != 0x91.toByte()) throw ReadException()
            val status = reply.last().toInt() and 255
            if (status != 0 && status != 0xAF) throw ReadException(status, "Clipper DESFire status %02X".format(status))
            val size = reply.size - 2
            if (result.size() + size > MAXIMUM_FILE_SIZE) throw ReadException()
            result.write(reply, 0, size)
            if (status == 0) return result.toByteArray()
            if (size == 0) throw ReadException(message = "Empty Clipper continuation")
            operation = 0xAF
            parameters = byteArrayOf()
        }
        throw ReadException(message = "Clipper continuation limit exceeded")
    }

    companion object {
        const val MAXIMUM_FILE_SIZE = 8192
        const val MAXIMUM_FRAMES = 256
    }
}
