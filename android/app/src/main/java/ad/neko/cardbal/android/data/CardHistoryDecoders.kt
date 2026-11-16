package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.SnapperPlusProtocol
import ad.neko.cardbal.android.nfc.ClipperDecoder
import kotlinx.datetime.Instant

/** The saved entry of the scanned card: by id, then by any shared identity (the T-Union side of a
 *  Macau Pass or Octopus card saved alone), then a positively identified Snapper on the same UID/shared AID. */
internal fun cardIndexForSnapshot(cards: List<SavedCardRecord>, snapshot: TransitCardSnapshot): Int {
    val exact = cards.indexOfFirst { it.id == snapshot.storageIdentifier }
    if (exact >= 0) return exact
    val aliases = snapshot.identityAliases
    val linked = cards.indexOfFirst { card -> card.identityAliases.any(aliases::contains) }
    if (linked >= 0) return linked
    val matching=cards.indices.filter { index ->
        val old=cards[index]
        val sameFamily=old.cardFamily.equals(snapshot.cardFamily,true) || snapshot.cardFamily.equals("Snapper+",true) && old.cardFamily.equals("T-money",true)
        sameFamily && old.technology==snapshot.technology && old.rawIdentifierValue.equals(snapshot.rawIdentifierValue,true) &&
            old.selectedAID.equals(snapshot.selectedAID,true) &&
            (old.realSerialNumber.isNullOrBlank() || snapshot.realSerialNumber.isNullOrBlank() || old.realSerialNumber==snapshot.realSerialNumber)
    }
    return matching.singleOrNull() ?: -1
}

/** The wallet after saving [snapshot]: it updates its saved entry, and earlier separate entries of the card become one. */
internal fun upsertingSnapshot(cards: List<SavedCardRecord>, snapshot: TransitCardSnapshot): List<SavedCardRecord> {
    val current = cards.toMutableList()
    val index = cardIndexForSnapshot(current, snapshot)
    val incomingFields = snapshot.resultFields.map { SavedCardField(it.title, it.value) }
    val updated = if (index >= 0) {
        val existing = current[index]
        val applications = if(snapshot.applications.isNullOrEmpty()) existing.applications else TransitApplication.merge(existing.applications ?: listOf(TransitApplication.fromSaved(existing)), snapshot.applications)
        val rescanned = existing.copy(
            id = snapshot.copy(applications = applications ?: snapshot.applications).storageIdentifier,
            cardFamily = snapshot.cardFamily,
            applications = applications,
            balanceText = snapshot.balanceText,
            balanceDetail = snapshot.balanceDetail,
            resultFields = incomingFields,
            scannedAt = snapshot.scannedAt,
            pmm = snapshot.pmm,
            systemCode = snapshot.systemCode,
            selectedAID = snapshot.selectedAID,
            realSerialNumber = snapshot.realSerialNumber?.takeIf { it.isNotBlank() } ?: existing.realSerialNumber,
            rawTransactions = mergeCardHistory(snapshot.cardFamily, existing.rawTransactions, snapshot.rawTransactions),
            rawTransitHistory = mergeCardHistory(snapshot.cardFamily, existing.rawTransitHistory, snapshot.rawTransitHistory),
            region = snapshot.region
                ?: snapshot.resultFields.firstOrNull { it.title == "Brand" }?.value
                ?: snapshot.resultFields.firstOrNull { it.title == "Region" }?.value
                ?: existing.region,
        )
        // A card with several applications keeps its family, primary and balance from all of them:
        // reading only the T-Union side of a Macau Pass card does not turn it into a T-Union card.
        if (applications != null && applications.size > 1) {
            val combined = rescanned.withApplications(applications)
            val primary = TransitApplication.primary(applications)
            if (primary == null || primary.selectedAID == snapshot.selectedAID) combined
            else combined.copy(resultFields = primary.fields, region = primary.region ?: combined.region)
        } else rescanned
    } else {
        SavedCardRecord.from(snapshot)
    }

    if (index >= 0) current[index] = updated else current.add(0, updated)
    // Earlier separate entries of this card (or any other) become one.
    return consolidateMatchingCards(current, updated.id)
}

internal fun mergeCardHistory(family: String, existing: List<String>, incoming: List<String>): List<String> {
    if (family.equals("Snapper+", ignoreCase = true) || family.equals("Snapper Plus", ignoreCase = true)) {
        return SnapperPlusProtocol.mergeHistory(incoming + existing)
    }
    if (family.equals("Clipper", ignoreCase = true)) {
        return AdditionalCardHistory.merge((incoming + existing).map(ClipperDecoder::canonicalHistoryRecord))
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
