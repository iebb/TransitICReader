package ad.neko.cardbal.android.util

fun ByteArray.hexString(): String = joinToString("") { "%02X".format(it) }

fun String.hexToBytes(): ByteArray {
    val clean = filterNot { it.isWhitespace() }
    if (clean.length % 2 != 0 || clean.any { it.digitToIntOrNull(16) == null }) return byteArrayOf()
    return clean.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}

fun ByteArray.leInt(start: Int, length: Int): Int {
    var value = 0
    for (i in 0 until length) value = value or ((this[start + i].toInt() and 0xff) shl (8 * i))
    return value
}

fun ByteArray.beInt(start: Int, length: Int): Int {
    var value = 0
    for (i in 0 until length) value = (value shl 8) or (this[start + i].toInt() and 0xff)
    return value
}

fun formatFeliCaId(value: String): String {
    val normalized = value.uppercase().filter { it.isLetterOrDigit() }
    return normalized.chunked(4).joinToString(" ")
}
