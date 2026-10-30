package ad.neko.cardbal.android.data

import android.content.Context
import ad.neko.cardbal.android.util.beInt
import ad.neko.cardbal.android.util.hexToBytes
import ad.neko.cardbal.android.util.leInt
import kotlinx.datetime.Instant
import java.time.LocalDateTime
import java.time.ZoneId

class TransactionDecoder(context: Context) {
    private val stationDb = StationDatabase.get(context)
    private val busResolver = BusResolver.get(context)

    fun transactionsFor(card: SavedCardRecord): List<TransitTransaction> {
        val records = mergeCardHistory(card.cardFamily, emptyList(), card.rawTransactions)
        val regular = records.mapIndexedNotNull { index, raw ->
            decode(raw, card, records, index, RawHistoryKind.Transactions, relatedContext = emptyList())
        }
        val transit = card.rawTransitHistory.mapIndexedNotNull { index, raw ->
            decode(raw, card, card.rawTransitHistory, index, RawHistoryKind.Transit, relatedContext = card.rawTransactions)
        }
        return (regular + transit).sortedWith(
            compareByDescending<TransitTransaction> { it.date?.toEpochMilliseconds() ?: Long.MIN_VALUE }
                .thenByDescending { it.recordCounter ?: it.recordNumber?.toLong() ?: Long.MIN_VALUE },
        )
    }

    fun routePointsFor(card: SavedCardRecord): List<StationPoint> {
        return stationPinsFor(card)
    }

    fun stationPinsFor(card: SavedCardRecord): List<StationPoint> {
        val pins = mutableListOf<StationPoint>()
        for (tx in transactionsFor(card)) {
            if (!shouldMapStationCodes(card, tx)) continue
            val entry = resolvePoint(card, tx.entryStationCode)
            val exit = resolvePoint(card, tx.exitStationCode)
            if (entry != null) pins.add(entry)
            if (exit != null && exit.code != entry?.code) pins.add(exit)
        }
        return pins.distinctBy { it.code }
    }

    fun routesFor(card: SavedCardRecord): List<StationRoute> {
        return transactionsFor(card).mapNotNull { tx ->
            if (!shouldMapStationCodes(card, tx)) return@mapNotNull null
            val entryCode = tx.entryStationCode ?: return@mapNotNull null
            val exitCode = tx.exitStationCode ?: return@mapNotNull null
            if (tx.category == TransactionCategory.bus || tx.category == TransactionCategory.busOn || tx.category == TransactionCategory.busOff) return@mapNotNull null
            val entry = resolvePoint(card, entryCode) ?: return@mapNotNull null
            val exit = resolvePoint(card, exitCode) ?: return@mapNotNull null
            if (entry.code == exit.code) return@mapNotNull null

            val path = routePath(card, entry, exit)
            if (path.size < 2) return@mapNotNull null
            StationRoute(
                id = tx.rawData ?: "$entryCode-$exitCode-${tx.recordNumber ?: ""}",
                title = "${entry.name} → ${exit.name}",
                points = path,
                rawData = tx.rawData,
            )
        }
    }

    private fun shouldMapStationCodes(card: SavedCardRecord, tx: TransitTransaction): Boolean {
        val family = card.cardFamily.lowercase()
        val isTUnion = "union" in family || "china" in family
        return when (tx.category) {
            TransactionCategory.train, TransactionCategory.trainOn, TransactionCategory.trainOff,
            TransactionCategory.tapOn, TransactionCategory.tapOff -> true
            TransactionCategory.bus, TransactionCategory.busOn, TransactionCategory.busOff -> isTUnion
            else -> false
        }
    }

    fun rawExplanationFor(card: SavedCardRecord, tx: TransitTransaction): RawRecordExplanation? {
        val raw = tx.rawData ?: return null
        val data = raw.hexToBytes()
        if (data.isEmpty()) return null
        val family = card.cardFamily.lowercase()
        return when {
            family == "snapper+" || family == "snapper plus" -> RawRecordExplanation(
                title = "Snapper+ raw record",
                summary = "SFI 4 transaction with its original optional SFI 3 companion; operator IDs are not station codes.",
                values = listOf(
                    RawRecordValue("Amount", formatCardMoney(tx.amount, "NZD", 2), "SFI 4 bytes 10–13"),
                    RawRecordValue("Currency", "NZD", "Snapper+ stored-value units are cents"),
                ),
            )
            family == "kmt" || family == "kartu multi trip" -> null
            "waon" in family -> explainWaon(data)
            "nanaco" in family -> explainNanaco(data)
            "edy" in family -> explainEdy(data)
            card.technology == "FeliCa" && tx.category in setOf(TransactionCategory.trainOn, TransactionCategory.trainOff, TransactionCategory.train) -> explainJapaneseTransit(data)
            card.technology == "FeliCa" -> explainJapaneseUse(data)
            card.technology == "ISO7816" -> explainIso(data)
            else -> null
        }
    }

    private fun resolvePoint(card: SavedCardRecord, code: String?): StationPoint? {
        val family = card.cardFamily.lowercase()
        return if ("union" in family || "china" in family) {
            stationDb.findTUnionStation(code)
        } else {
            stationDb.findJapaneseStation(code)
        }
    }

    private fun routePath(card: SavedCardRecord, entry: StationPoint, exit: StationPoint): List<StationPoint> {
        val family = card.cardFamily.lowercase()
        return if ("union" in family || "china" in family) {
            listOf(entry, exit)
        } else {
            stationDb.shortestJapanesePath(entry, exit)
        }
    }

    private fun decode(
        raw: String,
        card: SavedCardRecord,
        context: List<String>,
        index: Int,
        kind: RawHistoryKind,
        relatedContext: List<String>,
    ): TransitTransaction? {
        val data = raw.hexToBytes()
        if (data.isEmpty() || data.all { it == 0.toByte() }) return null
        val family = card.cardFamily.lowercase()
        return when {
            family == "snapper+" || family == "snapper plus" ->
                if (card.technology == "ISO7816" && kind == RawHistoryKind.Transactions) decodeSnapperHistory(data, raw) else null
            family == "kmt" || family == "kartu multi trip" -> null
            card.technology == "FeliCa" && kind == RawHistoryKind.Transit -> decodeJapaneseTransitActivity(data, raw, relatedContext)
            card.technology == "FeliCa" && "octopus" in family -> decodeOctopus(data, raw, context, index)
            card.technology == "FeliCa" && "waon" in family -> decodeWaonHistory(data, raw)
            card.technology == "FeliCa" && data.size >= 16 -> decodeJapaneseUse(data, raw, context, index)
            card.technology == "ISO7816" && ("union" in family || "china" in family) -> decodeTUnion(data, raw, index, kind)
            card.technology == "ISO7816" -> decodeIsoRecord(data, raw, index, family)
            else -> null
        }
    }

    private fun decodeJapaneseUse(data: ByteArray, raw: String, context: List<String>, index: Int): TransitTransaction? {
        if (data.size < 16) return null
        val balance = data.leInt(10, 2).toLong()
        val previousBalance = context.getOrNull(index + 1)?.hexToBytes()?.takeIf { it.size >= 12 }?.leInt(10, 2)
        val diff = previousBalance?.let { balance - it } ?: 0
        val rawDate = data.beInt(4, 2)
        val date = packedJapaneseDate(rawDate)
        val consoleType = data[0].toInt() and 0xff
        val processType = data[1].toInt() and 0xff
        val area = ((data[15].toInt() and 0xff) shr 6) and 0x03
        val entryLow = data.beInt(6, 2)
        val exitLow = data.beInt(8, 2)
        val stationFieldMode = japaneseStationFieldMode(data)
        val entryCode = if (stationFieldMode == JapaneseStationFieldMode.Rail && entryLow != 0) (area shl 16) or entryLow else null
        val exitCode = if (stationFieldMode == JapaneseStationFieldMode.Rail && exitLow != 0) (area shl 16) or exitLow else null
        val entry = entryCode?.let { stationDb.findJapaneseStation("%05X".format(it)) }
        val exit = exitCode?.let { stationDb.findJapaneseStation("%05X".format(it)) }
        val busOperator = if (stationFieldMode == JapaneseStationFieldMode.Bus) busResolver.resolve(entryLow) else null
        val category = when {
            isJapanesePurchaseLike(consoleType, processType) -> TransactionCategory.purchase
            stationFieldMode == JapaneseStationFieldMode.Bus -> TransactionCategory.bus
            stationFieldMode == JapaneseStationFieldMode.Rail -> TransactionCategory.train
            diff > 0 -> TransactionCategory.topUp
            diff < 0 -> TransactionCategory.payment
            else -> TransactionCategory.unknown
        }
        val terminalName = japaneseTerminalName(consoleType)
        val processName = japaneseProcessName(processType)
        val type = when (category) {
            TransactionCategory.topUp -> "Top-up"
            TransactionCategory.bus -> processName
            TransactionCategory.purchase -> processName
            TransactionCategory.payment -> "Spending"
            else -> processName
        }
        return TransitTransaction(
            date = date,
            amount = kotlin.math.abs(diff),
            terminalID = "$terminalName (0x%02X)".format(consoleType),
            recordNumber = data.beInt(13, 2),
            type = type,
            category = category,
            balanceAfter = balance,
            location = when {
                busOperator != null -> busOperator
                entry != null && exit != null -> "${entry.name} -> ${exit.name}"
                entry != null -> entry.name
                else -> null
            },
            entryStation = busOperator ?: entry?.name,
            exitStation = exit?.name,
            entryStationCode = entryCode?.let { "0x%05X".format(it) },
            exitStationCode = exitCode?.let { "0x%05X".format(it) },
            rawData = raw,
        )
    }

    private enum class JapaneseStationFieldMode {
        Rail, Bus
    }

    private fun japaneseStationFieldMode(data: ByteArray): JapaneseStationFieldMode? {
        if (data.size < 16) return null
        val consoleType = data[0].toInt() and 0xff
        val processType = data[1].toInt() and 0xff
        if (isJapanesePurchaseLike(consoleType, processType)) return null
        return when {
            processType == 13 || processType == 15 -> JapaneseStationFieldMode.Bus
            processType in japaneseRailProcessTypes -> JapaneseStationFieldMode.Rail
            else -> null
        }
    }

    private fun isJapanesePurchaseLike(consoleType: Int, processType: Int): Boolean {
        return consoleType == 199 || consoleType == 200 || processType in japanesePurchaseProcessTypes
    }

    private fun decodeJapaneseTransitActivity(data: ByteArray, raw: String, relatedContext: List<String>): TransitTransaction? {
        if (data.size < 16) return null
        val activityCode = data[0].toInt() and 0xff
        val subtypeCode = data[1].toInt() and 0xff
        val stationCode = data.beInt(2, 2)
        val deviceNumber = data.beInt(4, 2)
        val rawDate = data.beInt(6, 2)
        val hour = bcd(data[8])
        val minute = bcd(data[9])
        val amount = data.leInt(10, 2).toLong()
        val date = packedJapaneseDate(rawDate, hour, minute)
        val inferredStation = inferTransitStation(stationCode, date, relatedContext)
        val resolvedStationCode = inferredStation?.fullCode ?: stationCode
        val station = inferredStation?.station
        val type = when (activityCode) {
            0xA0 -> "Entry"
            0xA2 -> "Discount Entry"
            0x20 -> "Exit"
            else -> "Transit Activity (${transitSubtypeLabel(subtypeCode)})"
        }
        val category = when (activityCode) {
            0xA0, 0xA2 -> TransactionCategory.trainOn
            0x20 -> TransactionCategory.trainOff
            else -> TransactionCategory.train
        }
        return TransitTransaction(
            date = date,
            time = if (hour in 0..23 && minute in 0..59) "%02d:%02d".format(hour, minute) else null,
            amount = amount,
            terminalID = "Gate Device %04d".format(deviceNumber),
            recordNumber = deviceNumber,
            type = type,
            category = category,
            location = station?.name ?: "Station %04X".format(stationCode),
            entryStation = if (category == TransactionCategory.trainOn) station?.name else null,
            exitStation = if (category == TransactionCategory.trainOff) station?.name else null,
            entryStationCode = if (category == TransactionCategory.trainOn && station != null) "0x%05X".format(resolvedStationCode) else null,
            exitStationCode = if (category == TransactionCategory.trainOff && station != null) "0x%05X".format(resolvedStationCode) else null,
            rawData = raw,
        )
    }

    private fun decodeOctopus(data: ByteArray, raw: String, context: List<String>, index: Int): TransitTransaction? {
        if (data.size < 14) return null
        val balance = data.beInt(10, 4).toLong() / 10
        val previous = context.getOrNull(index + 1)?.hexToBytes()?.takeIf { it.size >= 14 }?.beInt(10, 4)?.toLong()?.div(10)
        val diff = previous?.let { balance - it } ?: 0
        return TransitTransaction(
            amount = kotlin.math.abs(diff),
            type = if (diff > 0) "Transaction / Top-up" else "Transaction",
            category = if (diff > 0) TransactionCategory.topUp else TransactionCategory.payment,
            balanceAfter = balance,
            rawData = raw,
        )
    }

    private fun decodeWaonHistory(data: ByteArray, raw: String): TransitTransaction? {
        if (data.size < 29) return null
        val sequence = data.leInt(13, 2)
        val type = data[17].toInt() and 0xff
        val packed = data.copyOfRange(18, 29)
        val year = 2005 + readMsbPackedBits(packed, 0, 5)
        val month = readMsbPackedBits(packed, 5, 4)
        val day = readMsbPackedBits(packed, 9, 5)
        val hour = readMsbPackedBits(packed, 14, 5)
        val minute = readMsbPackedBits(packed, 19, 6)
        val balance = readMsbPackedBits(packed, 25, 18).toLong()
        val usageAmount = readMsbPackedBits(packed, 43, 18).toLong()
        val chargeAmount = readMsbPackedBits(packed, 61, 17).toLong()
        val isTopUp = type == 0x0C || type == 0x10
        val amount = if (isTopUp) chargeAmount else usageAmount
        return TransitTransaction(
            date = localInstant(year, month, day, hour, minute),
            amount = amount,
            terminalID = formatUtf8OrHex(data.copyOfRange(0, 13)),
            recordNumber = sequence,
            type = waonTransactionTypeName(type),
            category = if (isTopUp) TransactionCategory.topUp else if (type == 0x04) TransactionCategory.payment else TransactionCategory.unknown,
            balanceAfter = balance,
            rawData = raw,
        )
    }

    private fun decodeTUnion(data: ByteArray, raw: String, index: Int, kind: RawHistoryKind): TransitTransaction? {
        return if (kind == RawHistoryKind.Transit || data.size >= 48) {
            decodeTUnionTravel(data, raw, index)
        } else {
            decodeTUnionPboc(data, raw, index)
        }
    }

    private fun decodeTUnionPboc(data: ByteArray, raw: String, index: Int): TransitTransaction? {
        if (data.size < 23) return null
        val amount = data.beInt(5, 4).toLong() / 100
        val typeByte = data[9].toInt() and 0xff
        val date = bcdDateTime(data, dateStart = 16, timeStart = 20, zoneId = "Asia/Shanghai")
        val type = tUnionPbocType(typeByte)
        return TransitTransaction(
            date = date,
            time = bcdTime(data, 20),
            amount = amount,
            terminalID = data.copyOfRange(10, 16).joinToString("") { "%02X".format(it) },
            recordNumber = index + 1,
            type = type.label,
            category = type.category,
            rawData = raw,
        )
    }

    private fun decodeTUnionTravel(data: ByteArray, raw: String, index: Int): TransitTransaction? {
        if (data.size < 48) return null
        val typeByte = data[0].toInt() and 0xff
        val subType = data[9].toInt() and 0xff
        val stationId = data.copyOfRange(10, 17).joinToString("") { "%02X".format(it) }
        val amount = data.beInt(17, 4).toLong() / 100
        val balance = data.beInt(21, 4).toLong() / 100
        val cityId = data.copyOfRange(32, 34).joinToString("") { "%02X".format(it) }
        val station = stationDb.findTUnionStation(cityId + stationId)
            ?: stationDb.findTUnionStation(stationId)
        val travelType = tUnionTravelType(typeByte, subType)
        val stationLabel = station?.name ?: "Station $stationId"
        return TransitTransaction(
            date = bcdDateTime(data, dateStart = 25, timeStart = 29, zoneId = "Asia/Shanghai"),
            time = bcdTime(data, 29),
            amount = amount,
            terminalID = data.copyOfRange(1, 9).joinToString("") { "%02X".format(it) },
            recordNumber = index + 1,
            type = travelType.label,
            category = travelType.category,
            balanceAfter = balance,
            location = stationLabel,
            entryStation = if (travelType.isEntry) stationLabel else null,
            exitStation = if (travelType.isExit) stationLabel else null,
            entryStationCode = if (travelType.isEntry) station?.code ?: (cityId + stationId) else null,
            exitStationCode = if (travelType.isExit) station?.code ?: (cityId + stationId) else null,
            rawData = raw,
        )
    }

    private fun decodeIsoRecord(data: ByteArray, raw: String, index: Int, family: String): TransitTransaction? {
        val balance = if (data.size >= 8) data.takeLast(4).fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 0xff) } else null
        return TransitTransaction(
            amount = 0,
            terminalID = "Record #${index + 1}",
            recordNumber = index + 1,
            type = if ("tmoney" in family || "t-money" in family) "Korean transit record" else "Card record",
            category = TransactionCategory.unknown,
            balanceAfter = balance,
            rawData = raw,
        )
    }

    private fun packedJapaneseDate(rawDate: Int, hour: Int? = null, minute: Int? = null): Instant? {
        val year = 2000 + ((rawDate shr 9) and 0x7f)
        val month = (rawDate shr 5) and 0x0f
        val day = rawDate and 0x1f
        if (month !in 1..12 || day !in 1..31) return null
        val local = LocalDateTime.of(year, month, day, hour?.takeIf { it in 0..23 } ?: 0, minute?.takeIf { it in 0..59 } ?: 0)
        return Instant.fromEpochMilliseconds(local.atZone(ZoneId.of("Asia/Tokyo")).toInstant().toEpochMilli())
    }

    private data class InferredTransitStation(
        val fullCode: Int,
        val station: StationPoint,
    )

    private fun inferTransitStation(code: Int, date: Instant?, relatedContext: List<String>): InferredTransitStation? {
        stationDb.findJapaneseStation("%04X".format(code))?.let { direct ->
            return InferredTransitStation(code, direct)
        }

        var best: Pair<Long, InferredTransitStation>? = null
        for (raw in relatedContext) {
            val block = raw.hexToBytes()
            val candidate = inferCandidateStation(block, targetLowCode = code, targetDate = date) ?: continue
            if (best == null || candidate.first < best!!.first) {
                best = candidate
            }
        }
        return best?.second
    }

    private fun inferCandidateStation(block: ByteArray, targetLowCode: Int, targetDate: Instant?): Pair<Long, InferredTransitStation>? {
        if (block.size < 16) return null
        if (japaneseStationFieldMode(block) != JapaneseStationFieldMode.Rail) return null
        val rawDate = block.beInt(4, 2)
        val candidateDate = packedJapaneseDate(rawDate)
        if (targetDate != null && candidateDate != null) {
            val delta = kotlin.math.abs(candidateDate.toEpochMilliseconds() - targetDate.toEpochMilliseconds())
            if (delta > 3L * 24L * 60L * 60L * 1000L) return null
        }

        val area = ((block[15].toInt() and 0xff) shr 6) and 0x03
        val entryLow = block.beInt(6, 2)
        val exitLow = block.beInt(8, 2)
        if (entryLow != targetLowCode && exitLow != targetLowCode) return null

        val fullCode = (area shl 16) or targetLowCode
        val station = stationDb.findJapaneseStation("%05X".format(fullCode)) ?: return null
        val distance = if (targetDate != null && candidateDate != null) {
            kotlin.math.abs(candidateDate.toEpochMilliseconds() - targetDate.toEpochMilliseconds())
        } else {
            0L
        }
        return distance to InferredTransitStation(fullCode, station)
    }

    private fun bcd(byte: Byte): Int {
        val value = byte.toInt() and 0xff
        val high = (value shr 4) and 0x0f
        val low = value and 0x0f
        return if (high <= 9 && low <= 9) high * 10 + low else -1
    }

    private fun bcdTime(data: ByteArray, start: Int): String? {
        if (data.size < start + 3) return null
        val hour = bcd(data[start])
        val minute = bcd(data[start + 1])
        val second = bcd(data[start + 2])
        if (hour !in 0..23 || minute !in 0..59 || second !in 0..59) return null
        return "%02d:%02d".format(hour, minute)
    }

    private fun bcdDateTime(data: ByteArray, dateStart: Int, timeStart: Int, zoneId: String): Instant? {
        if (data.size < dateStart + 4 || data.size < timeStart + 3) return null
        val century = bcd(data[dateStart])
        val year = bcd(data[dateStart + 1])
        val month = bcd(data[dateStart + 2])
        val day = bcd(data[dateStart + 3])
        val hour = bcd(data[timeStart])
        val minute = bcd(data[timeStart + 1])
        val second = bcd(data[timeStart + 2])
        if (century < 0 || year < 0 || month !in 1..12 || day !in 1..31) return null
        if (hour !in 0..23 || minute !in 0..59 || second !in 0..59) return null
        val local = LocalDateTime.of(century * 100 + year, month, day, hour, minute, second)
        return Instant.fromEpochMilliseconds(local.atZone(ZoneId.of(zoneId)).toInstant().toEpochMilli())
    }

    private data class TUnionType(
        val label: String,
        val category: TransactionCategory,
        val isEntry: Boolean = false,
        val isExit: Boolean = false,
    )

    private fun tUnionPbocType(type: Int): TUnionType = when (type) {
        0x02 -> TUnionType("Top-up", TransactionCategory.topUp)
        0x06 -> TUnionType("Single Purchase", TransactionCategory.purchase)
        0x09 -> TUnionType("Compound Purchase", TransactionCategory.purchase)
        0x04 -> TUnionType("Adjustment", TransactionCategory.adjustment)
        0x05 -> TUnionType("Cash Withdrawal", TransactionCategory.refund)
        else -> TUnionType("Transaction %02X".format(type), TransactionCategory.unknown)
    }

    private fun tUnionTravelType(type: Int, subType: Int): TUnionType = when (type) {
        0x03 -> TUnionType(
            label = if (subType == 0x02) "Bus Boarding" else "Entry",
            category = if (subType == 0x02) TransactionCategory.busOn else TransactionCategory.trainOn,
            isEntry = true,
        )
        0x04 -> TUnionType(
            label = if (subType == 0x02) "Bus Exit" else "Exit",
            category = if (subType == 0x02) TransactionCategory.busOff else TransactionCategory.trainOff,
            isExit = true,
        )
        0x02, 0x06 -> TUnionType(
            label = if (subType == 0x02) "Bus Trip" else "Transit Trip",
            category = if (subType == 0x02) TransactionCategory.bus else TransactionCategory.train,
        )
        else -> TUnionType("Travel %02X".format(type), TransactionCategory.unknown)
    }

    private fun transitSubtypeLabel(code: Int): String = when (code) {
        0x00 -> "Standard"
        0x04 -> "Discount"
        0x08 -> "Transfer"
        else -> "%02X".format(code)
    }

    private fun explainWaon(data: ByteArray): RawRecordExplanation? {
        if (data.size < 29) return null
        val terminal = data.copyOfRange(0, 13)
        val sequence = data.leInt(13, 2)
        val type = data[17].toInt() and 0xff
        val packed = data.copyOfRange(18, 29)
        val year = 2005 + readMsbPackedBits(packed, 0, 5)
        val month = readMsbPackedBits(packed, 5, 4)
        val day = readMsbPackedBits(packed, 9, 5)
        val hour = readMsbPackedBits(packed, 14, 5)
        val minute = readMsbPackedBits(packed, 19, 6)
        val balance = readMsbPackedBits(packed, 25, 18)
        val usageAmount = readMsbPackedBits(packed, 43, 18)
        val chargeAmount = readMsbPackedBits(packed, 61, 17)
        return RawRecordExplanation(
            title = "WAON raw record",
            summary = "WAON history comes from service 680B. Each record is two 16-byte blocks; bytes 18-28 are MSB-first packed fields.",
            values = listOf(
                RawRecordValue("Terminal", formatUtf8OrHex(terminal), terminal.hex(), byteRange = 0..12),
                RawRecordValue("Sequence", sequence.toString(), data.copyOfRange(13, 15).hex(), byteRange = 13..14),
                RawRecordValue("Transaction Type", waonTransactionTypeName(type), "0x%02X".format(type), byteRange = 17..17),
                RawRecordValue("Packed DateTime", "%04d-%02d-%02d %02d:%02d".format(year, month, day, hour, minute), packed.hex(), byteRange = 18..28),
                RawRecordValue("Balance After", "¥%,d".format(balance), "bits 25-42", byteRange = 21..23, bitRange = 25..42),
                RawRecordValue("Usage Amount", "¥%,d".format(usageAmount), "bits 43-60", byteRange = 23..25, bitRange = 43..60),
                RawRecordValue("Charge Amount", "¥%,d".format(chargeAmount), "bits 61-77", byteRange = 25..27, bitRange = 61..77),
            ),
        )
    }

    private fun explainJapaneseUse(data: ByteArray): RawRecordExplanation? {
        if (data.size < 16) return null
        val rawDate = data.beInt(4, 2)
        val year = 2000 + ((rawDate shr 9) and 0x7f)
        val month = (rawDate shr 5) and 0x0f
        val day = rawDate and 0x1f
        val area = ((data[15].toInt() and 0xff) shr 6) and 0x03
        return RawRecordExplanation(
            title = "Japanese IC raw record",
            summary = "Standard transit history service 090F stores one 16-byte record. Station codes are combined with the area bits in byte 15.",
            values = listOf(
                RawRecordValue("Terminal", "${japaneseTerminalName(data[0].toInt() and 0xff)} (0x%02X)".format(data[0]), data.copyOfRange(0, 1).hex(), byteRange = 0..0),
                RawRecordValue("Process", "${japaneseProcessName(data[1].toInt() and 0xff)} (0x%02X)".format(data[1]), data.copyOfRange(1, 2).hex(), byteRange = 1..1),
                RawRecordValue("Date", "%04d-%02d-%02d".format(year, month, day), data.copyOfRange(4, 6).hex(), byteRange = 4..5),
                RawRecordValue("Entry Code", "0x%05X".format((area shl 16) or data.beInt(6, 2)), data.copyOfRange(6, 8).hex(), byteRange = 6..7),
                RawRecordValue("Exit Code", "0x%05X".format((area shl 16) or data.beInt(8, 2)), data.copyOfRange(8, 10).hex(), byteRange = 8..9),
                RawRecordValue("Balance After", "¥%,d".format(data.leInt(10, 2)), data.copyOfRange(10, 12).hex(), byteRange = 10..11),
                RawRecordValue("Record Number", data.beInt(13, 2).toString(), data.copyOfRange(13, 15).hex(), byteRange = 13..14),
            ),
        )
    }

    private fun explainJapaneseTransit(data: ByteArray): RawRecordExplanation? {
        if (data.size < 16) return null
        return RawRecordExplanation(
            title = "Transit activity raw record",
            summary = "Gate activity services 108F/10CB store station, device, date, BCD time, fare/pass fields, and pass station hints.",
            values = listOf(
                RawRecordValue("Activity", "0x%02X".format(data[0]), data.copyOfRange(0, 1).hex(), byteRange = 0..0),
                RawRecordValue("Subtype", "0x%02X".format(data[1]), data.copyOfRange(1, 2).hex(), byteRange = 1..1),
                RawRecordValue("Station Code", "0x%04X".format(data.beInt(2, 2)), data.copyOfRange(2, 4).hex(), byteRange = 2..3),
                RawRecordValue("Device", data.beInt(4, 2).toString(), data.copyOfRange(4, 6).hex(), byteRange = 4..5),
                RawRecordValue("Date", data.copyOfRange(6, 8).hex(), data.copyOfRange(6, 8).hex(), byteRange = 6..7),
                RawRecordValue("BCD Time", "%02d:%02d".format(bcd(data[8]), bcd(data[9])), data.copyOfRange(8, 10).hex(), byteRange = 8..9),
                RawRecordValue("Amount", "¥%,d".format(data.leInt(10, 2)), data.copyOfRange(10, 12).hex(), byteRange = 10..11),
            ),
        )
    }

    private fun explainEdy(data: ByteArray): RawRecordExplanation? {
        if (data.size < 16) return null
        return RawRecordExplanation(
            title = "Edy raw record",
            summary = "Edy history records store type, sequence, packed elapsed date/time, amount, and balance in a 16-byte block.",
            values = listOf(
                RawRecordValue("Type", "0x%02X".format(data[0]), data.copyOfRange(0, 1).hex(), byteRange = 0..0),
                RawRecordValue("Sequence", data.beInt(2, 2).toString(), data.copyOfRange(2, 4).hex(), byteRange = 2..3),
                RawRecordValue("Packed DateTime", data.beInt(4, 4).toString(), data.copyOfRange(4, 8).hex(), byteRange = 4..7),
                RawRecordValue("Amount", "¥%,d".format(data.beInt(8, 4)), data.copyOfRange(8, 12).hex(), byteRange = 8..11),
                RawRecordValue("Balance After", "¥%,d".format(data.beInt(12, 4)), data.copyOfRange(12, 16).hex(), byteRange = 12..15),
            ),
        )
    }

    private fun explainNanaco(data: ByteArray): RawRecordExplanation? {
        if (data.size < 16) return null
        return RawRecordExplanation(
            title = "nanaco raw record",
            summary = "nanaco history service 564F stores transaction type, amount, balance, packed date/time, and sequence.",
            values = listOf(
                RawRecordValue("Type", "0x%02X".format(data[0]), data.copyOfRange(0, 1).hex(), byteRange = 0..0),
                RawRecordValue("Amount", "¥%,d".format(data.beInt(1, 4)), data.copyOfRange(1, 5).hex(), byteRange = 1..4),
                RawRecordValue("Balance After", "¥%,d".format(data.beInt(5, 4)), data.copyOfRange(5, 9).hex(), byteRange = 5..8),
                RawRecordValue("Packed DateTime", data.beInt(9, 4).toString(), data.copyOfRange(9, 13).hex(), byteRange = 9..12),
                RawRecordValue("Sequence", data.beInt(13, 2).toString(), data.copyOfRange(13, 15).hex(), byteRange = 13..14),
            ),
        )
    }

    private fun explainIso(data: ByteArray): RawRecordExplanation = RawRecordExplanation(
        title = "ISO7816 raw record",
        summary = "This payload is the APDU record body returned by READ RECORD after status word 9000 was removed.",
        values = listOf(
            RawRecordValue("Length", "${data.size} bytes", data.hex(), byteRange = data.indices),
            RawRecordValue("Leading Bytes", data.take(8).toByteArray().hex(), "bytes 0-7", byteRange = 0..minOf(7, data.lastIndex)),
            RawRecordValue("Trailing Bytes", data.takeLast(8).toByteArray().hex(), "last 8 bytes", byteRange = maxOf(0, data.size - 8)..data.lastIndex),
        ),
    )

    private fun readMsbPackedBits(data: ByteArray, offset: Int, length: Int): Int {
        var value = 0
        for (bitIndex in offset until offset + length) {
            val byte = data[bitIndex / 8].toInt() and 0xff
            val bit = (byte shr (7 - (bitIndex % 8))) and 0x01
            value = (value shl 1) or bit
        }
        return value
    }

    private fun localInstant(year: Int, month: Int, day: Int, hour: Int, minute: Int): Instant? {
        if (month !in 1..12 || day !in 1..31 || hour !in 0..23 || minute !in 0..59) return null
        return Instant.fromEpochMilliseconds(LocalDateTime.of(year, month, day, hour, minute).atZone(ZoneId.of("Asia/Tokyo")).toInstant().toEpochMilli())
    }

    private fun waonTransactionTypeName(type: Int): String = when (type) {
        0x04 -> "Payment"
        0x0C, 0x10 -> "Top-up"
        else -> "Transaction 0x%02X".format(type)
    }

    private fun japaneseTerminalName(code: Int): String = when (code) {
        3 -> "Fare Adjustment Machine"
        4 -> "Portable Terminal"
        5 -> "On-board Terminal"
        7, 8, 18 -> "Vending Machine"
        9 -> "Deposit Machine"
        20, 21 -> "Vending Machine etc."
        22 -> "Ticket Gate"
        23 -> "Simplified Ticket Gate"
        24, 25 -> "Counter Terminal"
        26 -> "Gate Terminal"
        27 -> "Mobile Phone"
        28 -> "Transfer Adjustment Machine"
        29 -> "Interconnecting Gate"
        31 -> "Simplified Deposit Machine"
        70, 72 -> "VIEW ALTTE"
        199 -> "Sales Terminal"
        200 -> "Vending Machine"
        else -> "Terminal $code"
    }

    private fun japaneseProcessName(code: Int): String = when (code) {
        1 -> "Fare Payment"
        2 -> "Top-up / Charge"
        3 -> "Magnetic Ticket Purchase"
        4 -> "Fare Adjustment"
        5 -> "Entry Fare Adjustment"
        6 -> "Window Processing"
        7 -> "New Card Issuance"
        8 -> "Window Deduction"
        13, 15 -> "Bus"
        17 -> "Card Re-issuance"
        19 -> "Shinkansen Payment"
        20 -> "Auto-charge (Entry Gate)"
        21 -> "Auto-charge (Exit Gate)"
        31 -> "Bus Charge"
        35 -> "Bus/Tram Special Ticket"
        70 -> "Goods Purchase"
        72 -> "Reward/Points Redemption"
        73 -> "Cash Deposit (POS)"
        74 -> "Transaction Cancellation"
        75 -> "Station Goods Purchase"
        132 -> "Other Co. Adjustment"
        133 -> "Other Co. Entry Adjustment"
        198 -> "Purchase (Cash Combined)"
        203 -> "Purchase (Cash Combined - Inside Gate)"
        else -> "Process $code"
    }

    private companion object {
        val japaneseRailProcessTypes = setOf(1, 4, 5, 19, 132, 133)
        val japanesePurchaseProcessTypes = setOf(70, 72, 73, 74, 75, 198, 203)
    }

    private fun formatUtf8OrHex(data: ByteArray): String = runCatching {
        data.toString(Charsets.UTF_8).trim('\u0000', ' ')
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: data.hex()

    private fun ByteArray.hex(): String = joinToString("") { "%02X".format(it) }
}
