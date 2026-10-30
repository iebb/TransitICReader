package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.SnapperPlusProtocol
import kotlinx.datetime.Instant

/** Upgrade only a positively identified Snapper on the same UID/shared AID. */
internal fun cardIndexForSnapshot(cards: List<SavedCardRecord>, snapshot: TransitCardSnapshot): Int {
    val exact = cards.indexOfFirst { it.id == snapshot.storageIdentifier }
    if (exact >= 0) return exact
    val matching=cards.indices.filter { index ->
        val old=cards[index]
        val sameFamily=old.cardFamily.equals(snapshot.cardFamily,true) || snapshot.cardFamily.equals("Snapper+",true) && old.cardFamily.equals("T-money",true)
        sameFamily && old.technology==snapshot.technology && old.rawIdentifierValue.equals(snapshot.rawIdentifierValue,true) &&
            old.selectedAID.equals(snapshot.selectedAID,true) &&
            (old.realSerialNumber.isNullOrBlank() || snapshot.realSerialNumber.isNullOrBlank() || old.realSerialNumber==snapshot.realSerialNumber)
    }
    return matching.singleOrNull() ?: -1
}

internal fun mergeCardHistory(family: String, existing: List<String>, incoming: List<String>): List<String> {
    if (family.equals("Snapper+", ignoreCase = true) || family.equals("Snapper Plus", ignoreCase = true)) {
        return SnapperPlusProtocol.mergeHistory(incoming + existing)
    }
    if (AdditionalCardHistory.handles(family)) return AdditionalCardHistory.merge(incoming + existing)
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
