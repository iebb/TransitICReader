package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.SnapperPlusProtocol
import kotlinx.datetime.Instant

/** Upgrade only a positively identified Snapper on the same UID/shared AID. */
internal fun cardIndexForSnapshot(cards: List<SavedCardRecord>, snapshot: TransitCardSnapshot): Int {
    val exact = cards.indexOfFirst { it.id == snapshot.storageIdentifier }
    if (exact >= 0) return exact
    if (!snapshot.cardFamily.equals("Snapper+", true) || snapshot.technology != "ISO7816" ||
        !snapshot.selectedAID.equals(SnapperPlusProtocol.APPLICATION_AID, true)) return -1
    return cards.indices.filter { index ->
        val old = cards[index]
        old.technology == "ISO7816" && old.rawIdentifierValue.equals(snapshot.rawIdentifierValue, true) &&
            old.selectedAID.equals(snapshot.selectedAID, true) &&
            (old.cardFamily.equals("T-money", true) || old.cardFamily.equals("Snapper+", true))
    }.singleOrNull() ?: -1
}

internal fun mergeCardHistory(family: String, existing: List<String>, incoming: List<String>): List<String> {
    if (family.equals("Snapper+", ignoreCase = true) || family.equals("Snapper Plus", ignoreCase = true)) {
        return SnapperPlusProtocol.mergeHistory(incoming + existing)
    }
    if (existing.isEmpty()) return incoming
    if (incoming.isEmpty()) return existing
    return (incoming + existing).distinct()
}

/** Decode the persisted envelope, so rescans/backup imports retain each trip's original timestamp. */
internal fun decodeSnapperHistory(data: ByteArray, raw: String): TransitTransaction? {
    val record = SnapperPlusProtocol.decodeHistory(data) ?: return null
    val category = when {
        record.transactionType == 2 -> TransactionCategory.topUp
        record.isTapOn == true -> TransactionCategory.tapOn
        record.isTapOn == false -> TransactionCategory.tapOff
        else -> TransactionCategory.payment
    }
    val type = when (category) {
        TransactionCategory.topUp -> "Top-up"
        TransactionCategory.tapOn -> "Tap-on"
        TransactionCategory.tapOff -> "Tap-off"
        else -> "Transit payment"
    }
    return TransitTransaction(
        date = record.timestampMillis?.let(Instant::fromEpochMilliseconds),
        amount = record.amountMinor, terminalID = record.operatorID,
        recordNumber = record.counter.takeIf { it <= Int.MAX_VALUE }?.toInt(), type = type, category = category,
        balanceAfter = record.balanceMinor, rawData = raw,
        currencyCode = "NZD", fractionDigits = 2, issuerTimeZone = "Pacific/Auckland",
        amountIsSigned = true, recordCounter = record.counter,
    )
}
