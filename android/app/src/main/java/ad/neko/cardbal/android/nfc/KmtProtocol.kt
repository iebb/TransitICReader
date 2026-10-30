package ad.neko.cardbal.android.nfc

/**
 * Independent KMT wire-field implementation, not a port of reference code.
 * Evidence: Metrodroid KMTTransitData at b910c1806fd86aa545223baf1d21fc5afe68eee2.
 * History stays raw because the reference's epoch transition is unverified.
 */
internal object KmtProtocol {
    const val SYSTEM_CODE = "90B7"
    // FeliCa service numbers are transmitted least-significant byte first.
    const val BALANCE_SERVICE = "1710"
    const val IDENTIFIER_SERVICE = "0B30"
    const val HISTORY_SERVICE = "0F20"
    const val HISTORY_READ_LIMIT = 20

    data class Balance(
        val amountIdr: Long,
        val lastTransactionAmountIdr: Long,
        val transactionCounter: Int,
    )

    data class Snapshot(
        val balance: Balance,
        val cardNumber: String?,
        val balanceBlock: ByteArray,
        val identifierBlock: ByteArray?,
        val historyBlocks: List<ByteArray>,
    )

    /** Production callbacks use FeliCaProtocol's addressed-frame/status checks. */
    fun read(poll: (String) -> Boolean, readBlock: (String, Int) -> ByteArray?): Snapshot? {
        if (!poll(SYSTEM_CODE)) return null
        val balanceBlock = readBlock(BALANCE_SERVICE, 0)?.copyOf() ?: return null
        val balance = parseBalance(balanceBlock) ?: return null
        val identifierBlock = readBlock(IDENTIFIER_SERVICE, 0)?.takeIf { it.size == 16 }?.copyOf()
        val history = mutableListOf<ByteArray>()
        for (index in 0 until HISTORY_READ_LIMIT) {
            val block = readBlock(HISTORY_SERVICE, index) ?: break
            if (block.size != 16) break
            // Do not mistake a record starting with zero bytes for an empty one.
            if (block.any { it != 0.toByte() }) history.add(block.copyOf())
        }
        return Snapshot(balance, identifierBlock?.let(::identifier), balanceBlock, identifierBlock, history)
    }

    fun parseBalance(block: ByteArray): Balance? {
        if (block.size != 16) return null
        fun amount(offset: Int): Long = (0 until 4).fold(0L) { value, byte ->
            value or ((block[offset + byte].toLong() and 0xffL) shl (byte * 8))
        }
        val counter = (13 until 16).fold(0) { value, byte ->
            (value shl 8) or (block[byte].toInt() and 0xff)
        }
        return Balance(amount(0), amount(4), counter)
    }

    /** Unknown binary identifier layouts remain raw; IDm remains available. */
    fun identifier(block: ByteArray): String? {
        if (block.size != 16) return null
        val text = block.dropLastWhile { it == 0.toByte() || it == 0x20.toByte() }
        if (text.isEmpty() || text.any { (it.toInt() and 0xff) !in 0x20..0x7e }) return null
        return text.toByteArray().toString(Charsets.US_ASCII).trim().takeIf { it.isNotEmpty() }
    }
}
