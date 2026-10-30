package ad.neko.cardbal.android.nfc

import java.time.LocalDate
import java.time.ZoneId

/** Independent read-only DESFire implementation; see docs/research/desfire-stored-value.md. */
internal class DesfireReadException(val status: Int? = null, message: String = "Invalid DESFire response", val optionalFile: Boolean = false) : Exception(message)

internal class DesfireReadSession(private val mode: WireMode, private val exchange: (ByteArray) -> ByteArray) {
    enum class WireMode { NATIVE, WRAPPED }
    data class File(val data: ByteArray, val recordSize: Int?)

    fun command(instruction: Int, payload: ByteArray = byteArrayOf()): ByteArray {
        if (instruction !in setOf(0x5a, 0xf5, 0xbd, 0xbb, 0x6a, 0x60, 0xaf) || payload.size > 255) {
            throw DesfireReadException(message = "Only supported read commands are permitted")
        }
        var operation = instruction
        var parameters = payload
        val output = java.io.ByteArrayOutputStream()
        repeat(64) {
            val request = if (mode == WireMode.NATIVE) byteArrayOf(operation.toByte()) + parameters
                else if (parameters.isEmpty()) byteArrayOf(0x90.toByte(), operation.toByte(), 0, 0, 0)
                else byteArrayOf(0x90.toByte(), operation.toByte(), 0, 0, parameters.size.toByte()) + parameters + byteArrayOf(0)
            val response = exchange(request)
            val status: Int
            val body: ByteArray
            if (mode == WireMode.NATIVE) {
                if (response.isEmpty()) throw DesfireReadException()
                status = response[0].toInt() and 255
                body = response.copyOfRange(1, response.size)
            } else {
                if (response.size < 2 || response[response.size - 2] != 0x91.toByte()) throw DesfireReadException()
                status = response.last().toInt() and 255
                body = response.copyOfRange(0, response.size - 2)
            }
            if (output.size() + body.size > 65_536) throw DesfireReadException(message = "DESFire response exceeds read limit")
            if (status != 0 && status != 0xaf) throw DesfireReadException(status, "DESFire read was refused")
            output.write(body)
            if (status == 0) return output.toByteArray()
            operation = 0xaf
            parameters = byteArrayOf()
        }
        throw DesfireReadException(message = "DESFire chaining exceeds read limit")
    }

    /** Canonical NXP AID numbers are transmitted as three LE bytes. */
    fun selectApplication(aid: Int) {
        if (aid !in 0..0xffffff) throw DesfireReadException()
        val response = command(0x5a, ByteArray(3) { (aid shr (it * 8)).toByte() })
        if (response.isNotEmpty()) throw DesfireReadException()
    }

    fun readFile(number: Int): File {
        if (number !in 0..255) throw DesfireReadException()
        val settings = command(0xf5, byteArrayOf(number.toByte()))
        if (settings.size < 4) throw DesfireReadException()
        if (settings[1] != 0.toByte()) throw DesfireReadException(message = "Authenticated file is not readable", optionalFile = true)
        fun le24(start: Int) = (0 until 3).fold(0) { n, i -> n or ((settings[start + i].toInt() and 255) shl (8 * i)) }
        val size: Int
        val record: Int?
        val instruction: Int
        when (settings[0].toInt() and 255) {
            0, 1 -> {
                if (settings.size != 7) throw DesfireReadException()
                size = le24(4); record = null; instruction = 0xbd
            }
            3, 4 -> {
                if (settings.size != 13) throw DesfireReadException()
                val width = le24(4); val maximum = le24(7); val count = le24(10)
                if (width !in 1..4096 || count > maximum || count > 256) throw DesfireReadException()
                size = width * count; record = width; instruction = 0xbb
            }
            else -> throw DesfireReadException(message = "Unsupported DESFire file type", optionalFile = true)
        }
        if (size > 65_536) throw DesfireReadException()
        if (size == 0) return File(byteArrayOf(), record)
        val data = command(instruction, byteArrayOf(number.toByte(), 0, 0, 0, 0, 0, 0))
        if (data.size != size) throw DesfireReadException()
        return File(data, record)
    }
}

internal object StoredValueProtocol {
    data class Snapshot(
        val family: String, val currencyCode: String, val fractionDigits: Int,
        val balanceMinor: Long?, val serial: String?, val metadata: Map<String, String>,
        val rawTransactions: List<String>, val passes: List<Pass>,
    )
    data class History(
        val family: String, val currencyCode: String, val issuerTimeZone: String,
        val dateEpochSeconds: Long?, val endDateEpochSeconds: Long?, val amountMinor: Long?,
        val balanceMinor: Long?, val kind: String, val label: String, val counter: Int?,
        val locationCode: String?, val route: String?, val rawEnvelope: String,
    )
    data class Pass(
        val family: String, val label: String, val productCode: Int, val zoneCode: Int,
        val validFromEpochSeconds: Long?, val validToEpochSeconds: Long?,
    )
    private data class Format(val tag: Int, val aid: Int, val family: String, val currency: String)
    private val formats = listOf(
        Format(1, 0x534531, "Opal", "AUD"), Format(3, 0xef2014, "HSL", "EUR"),
        Format(2, 0xef2011, "HSL", "EUR"), Format(4, 0xab1000, "Waltti", "EUR"),
        Format(5, 0xf21190, "Clipper", "USD"),
    )

    fun readFirst(mode: DesfireReadSession.WireMode, exchange: (ByteArray) -> ByteArray): Snapshot? {
        val session = DesfireReadSession(mode, exchange)
        for (format in formats) {
            try { session.selectApplication(format.aid) }
            catch (error: DesfireReadException) { if (error.status != null) continue else throw error }
            val files = mutableMapOf<Int, ByteArray>()
            val records = mutableMapOf<Int, Int>()
            val wanted = when (format.tag) { 1 -> listOf(7); 5 -> listOf(2, 8, 14, 4); else -> listOf(2, 8, 4, 1, 3) }
            for (file in wanted) {
                try {
                    val read = session.readFile(file)
                    files[file] = read.data
                    read.recordSize?.let { records[file] = it }
                } catch (error: DesfireReadException) {
                    if (error.status == null && !error.optionalFile) throw error
                }
            }
            parseFiles(format.tag, files, records)?.let { return it }
        }
        return null
    }

    fun parseFiles(tag: Int, files: Map<Int, ByteArray>, recordSizes: Map<Int, Int> = emptyMap()): Snapshot? {
        val format = formats.find { it.tag == tag } ?: return null
        var balance: Long? = null
        var serial: String? = null
        val raw = mutableListOf<String>()
        val metadata = mutableMapOf("generation" to "DESFire public files", "applicationAID" to "%06X".format(format.aid))
        when (tag) {
            1 -> {
                val data = files[7]?.takeIf { it.size >= 16 }?.copyOfRange(0, 16) ?: return null
                val bits = Bits(data.reversedArray())
                balance = bits.signed(54, 21)
                val number = bits.unsigned(96, 32); val digit = bits.unsigned(92, 4)
                if (number != null && digit != null && digit <= 9) serial = (3_085_220_000_000_000L + number * 10 + digit).toString()
                raw.add(envelope(tag, 1, 0, data))
                metadata["scope"] = "Balance and last-event summary; not full history"
            }
            5 -> {
                files[2]?.takeIf { it.size >= 20 }?.let { balance = Bits(it).signed(144, 16) }
                files[8]?.let { serial = Bits(it).unsigned(8, 32)?.toString() }
                for ((file, kind) in listOf(14 to 3, 4 to 2)) {
                    val data = files[file]?.takeIf { it.size % 32 == 0 } ?: continue
                    for (offset in data.indices step 32) raw.add(envelope(tag, kind, offset / 32, data.copyOfRange(offset, offset + 32)))
                }
                metadata["scope"] = "Older DESFire generation; newer Clipper generations are not decoded"
            }
            else -> {
                files[2]?.let { balance = Bits(it).unsigned(0, 20); raw.add(envelope(tag, 2, 0, it)) }
                files[8]?.takeIf { it.size >= 10 }?.let { serial = hex(it.copyOfRange(1, 10)) }
                val records = files[4]; val width = recordSizes[4]
                if (records != null && width != null && width >= 12 && records.size % width == 0) {
                    for (offset in records.indices step width) raw.add(envelope(tag, 3, offset / width, records.copyOfRange(offset, offset + width)))
                }
                files[1]?.let { raw.add(envelope(tag, 4, 0, it)) }
                files[3]?.let { raw.add(envelope(tag, 5, 0, it)) }
                metadata["scope"] = "HSL V1/V2 or Waltti DESFire public purse, logs and ticket products"
            }
        }
        val records = raw.filter { it.isNotEmpty() }
        val passes = parsePasses(records)
        if (balance == null && parseHistories(records).isEmpty() && passes.isEmpty()) return null
        return Snapshot(format.family, format.currency, 2, balance, serial, metadata, records, passes)
    }

    // DFSV + version + format + kind + index BE16 + payload length BE16.
    fun envelope(tag: Int, kind: Int, index: Int, data: ByteArray): String {
        if (formats.none { it.tag == tag } || kind !in 1..5 || index !in 0..65535 || data.size !in 1..4096) return ""
        return hex(byteArrayOf(0x44, 0x46, 0x53, 0x56, 1, tag.toByte(), kind.toByte(),
            (index shr 8).toByte(), index.toByte(), (data.size shr 8).toByte(), data.size.toByte()) + data)
    }
    private data class Envelope(val tag: Int, val kind: Int, val index: Int, val data: ByteArray)
    private fun unpack(value: String): Envelope? {
        if (value.length % 2 != 0 || value.length > (4096 + 11) * 2 || !value.matches(Regex("[0-9a-fA-F]+"))) return null
        val bytes = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        if (bytes.size < 12 || !bytes.copyOfRange(0, 5).contentEquals(byteArrayOf(0x44, 0x46, 0x53, 0x56, 1))) return null
        val tag = bytes[5].toInt() and 255; val kind = bytes[6].toInt() and 255
        val length = (bytes[9].toInt() and 255) * 256 + (bytes[10].toInt() and 255)
        if (formats.none { it.tag == tag } || kind !in 1..5 || length != bytes.size - 11) return null
        return Envelope(tag, kind, (bytes[7].toInt() and 255) * 256 + (bytes[8].toInt() and 255), bytes.copyOfRange(11, bytes.size))
    }

    fun parseHistory(raw: String, expectedFamily: String? = null): History? {
        val item = unpack(raw) ?: return null
        val format = formats.first { it.tag == item.tag }
        if ((expectedFamily != null && format.family != expectedFamily) || item.data.all { it == 0.toByte() }) return null
        val bits = Bits(item.data)
        var date: Long? = null; var end: Long? = null; var amount: Long? = null; var balance: Long? = null
        var counter: Int? = null; var location: String? = null; var route: String? = null
        var kind = "trip"; var label = "Journey"; var zone = "Europe/Helsinki"
        when {
            item.tag == 1 -> {
                if (item.kind != 1 || item.data.size != 16) return null
                val opal = Bits(item.data.reversedArray())
                val action = opal.unsigned(21, 4) ?: return null
                if (action == 0L) return null
                val day = opal.unsigned(39, 15) ?: return null; val minute = opal.unsigned(28, 11) ?: return null
                zone = "Australia/Sydney"; date = localTime(1980, day.toInt(), minute.toInt(), zone)
                balance = opal.signed(54, 21); counter = opal.unsigned(75, 16)?.toInt(); kind = "event"
                label = when (action) { in 1..6 -> "Tap on"; in 7..10 -> "Tap off"; 11L -> "Tap-on reversal"; 12L -> "Tap rejected"; else -> "Last event $action" }
            }
            item.tag == 5 -> {
                if (item.data.size != 32 || item.kind !in 2..3) return null
                zone = "America/Los_Angeles"; location = "Agency ${bits.unsigned(16, 16)}"
                if (item.kind == 2) {
                    val time = bits.unsigned(32, 32) ?: return null
                    if (time == 0L) return null
                    amount = bits.unsigned(112, 16) ?: return null; date = time - 2_208_988_800L
                    kind = "reload"; label = "Reload"
                } else {
                    if (bits.unsigned(16, 16) == 0L) return null
                    amount = -(bits.unsigned(48, 16) ?: return null)
                    bits.unsigned(96, 32)?.takeIf { it != 0L }?.let { date = it - 2_208_988_800L }
                    bits.unsigned(128, 32)?.takeIf { it != 0L }?.let { end = it - 2_208_988_800L }
                    route = bits.unsigned(224, 16)?.toString()
                    location += " · ${bits.unsigned(160, 16)} → ${bits.unsigned(176, 16)}"
                }
            }
            item.kind == 2 -> {
                val day = bits.unsigned(20, 14) ?: return null
                if (day == 0L) return null
                val minute = bits.unsigned(34, 11) ?: return null
                // The current purse is not this older reload's balance after.
                amount = bits.unsigned(45, 20) ?: return null
                date = localTime(1997, day.toInt(), minute.toInt(), zone); kind = "reload"; label = "Value reload"
            }
            item.kind == 3 -> {
                if (item.data.size < 12) return null
                val day = bits.unsigned(1, 14) ?: return null; val minute = bits.unsigned(15, 11) ?: return null
                if (day == 0L && minute == 0L) return null
                amount = -(bits.unsigned(51, 14) ?: return null)
                balance = bits.unsigned(if (item.tag == 3) 71 else 70, 20)
                date = localTime(1997, day.toInt(), minute.toInt(), zone)
            }
            item.kind == 4 || item.kind == 5 -> {
                val start = if (item.kind == 4) when (item.tag) { 2 -> 192; 3 -> 208; else -> 280 }
                    else when (item.tag) { 2 -> 144; 3 -> 286; else -> 168 }
                val day = bits.unsigned(start, 14) ?: return null; val minute = bits.unsigned(start + 14, 11) ?: return null
                if (day == 0L && minute == 0L) return null
                date = localTime(1997, day.toInt(), minute.toInt(), zone); label = "Ticket validation"
                if (item.tag != 4) route = bits.unsigned(start + 41, 14)?.toString()
            }
            else -> return null
        }
        return History(format.family, format.currency, zone, date, end, amount, balance, kind, label, counter, location, route, raw)
    }

    fun parseHistories(raw: List<String>, expectedFamily: String? = null): List<History> {
        val events = raw.mapNotNull { parseHistory(it, expectedFamily) }
        val filtered = events.filter { event ->
            event.family !in listOf("HSL", "Waltti") || event.amountMinor != null || event.dateEpochSeconds == null ||
                events.count { it.family == event.family && it.kind == "trip" && it.dateEpochSeconds == event.dateEpochSeconds && it.amountMinor != null } != 1
        }
        fun clipperKey(event: History): String? {
            if (event.family != "Clipper" || event.kind != "trip" || event.dateEpochSeconds == null) return null
            val item = unpack(event.rawEnvelope) ?: return null
            val bits = Bits(item.data)
            return "${event.dateEpochSeconds}:${bits.unsigned(16, 16)}:${bits.unsigned(160, 16)}:${bits.unsigned(224, 16)}"
        }
        val result = mutableListOf<History>()
        val reloadSummaries = mutableSetOf<String>()
        for (event in filtered) {
            if (event.family in listOf("HSL", "Waltti") && event.kind == "reload") {
                val item = unpack(event.rawEnvelope)!!
                if (item.kind == 2) {
                    val summary = item.data.copyOf()
                    summary[0] = 0; summary[1] = 0; summary[2] = (summary[2].toInt() and 0x0f).toByte()
                    if (!reloadSummaries.add("${item.tag}:${hex(summary)}")) continue
                }
            }
            val key = clipperKey(event)
            val index = if (key == null) -1 else result.indexOfFirst { clipperKey(it) == key }
            if (index >= 0) {
                val old = result[index]
                if (old.endDateEpochSeconds == null && event.endDateEpochSeconds != null) { result[index] = event; continue }
                if (old.endDateEpochSeconds != null && event.endDateEpochSeconds == null) continue
                if (old.endDateEpochSeconds == event.endDateEpochSeconds && old.amountMinor == event.amountMinor) continue
            }
            result.add(event)
        }
        return result
    }

    fun parsePasses(raw: List<String>, expectedFamily: String? = null): List<Pass> = raw.flatMap { value ->
        val item = unpack(value) ?: return@flatMap emptyList()
        val format = formats.first { it.tag == item.tag }
        if (item.tag !in 2..4 || item.kind !in 4..5 || (expectedFamily != null && format.family != expectedFamily)) return@flatMap emptyList()
        if (item.kind == 4) {
            val width = when (item.tag) { 2 -> 6; 3 -> 7; else -> 10 }
            (0..1).mapNotNull { index ->
                if (item.data.size < (index + 1) * width) return@mapNotNull null
                val data = item.data.copyOfRange(index * width, (index + 1) * width)
                if (data.all { it == 0.toByte() }) return@mapNotNull null
                val bits = Bits(data)
                val productOffset = when (item.tag) { 2 -> 0; 3 -> 1; else -> 12 }
                val areaOffset = when (item.tag) { 2 -> 15; 3 -> 17; else -> 27 }
                val dateOffset = when (item.tag) { 2 -> 19; 3 -> 23; else -> 33 }
                val product = bits.unsigned(productOffset, 14) ?: return@mapNotNull null
                val area = bits.unsigned(areaOffset, if (item.tag == 2) 4 else 6) ?: return@mapNotNull null
                val start = bits.unsigned(dateOffset, 14) ?: return@mapNotNull null
                val end = bits.unsigned(dateOffset + 14, 14) ?: return@mapNotNull null
                if (product == 0L || (item.tag == 4 && start == 999L && end == 0L) || (start != 0L && end != 0L && end < start)) return@mapNotNull null
                Pass(format.family, "Season pass", product.toInt(), area.toInt(),
                    if (start == 0L) null else localTime(1997, start.toInt(), 0, "Europe/Helsinki"),
                    if (end == 0L) null else localTime(1997, end.toInt(), 0, "Europe/Helsinki"))
            }
        } else {
            val bits = Bits(item.data)
            val productOffset = when (item.tag) { 3 -> 1; 4 -> 8; else -> 0 }
            val validity = when (item.tag) { 2 -> 88; 3 -> 205; else -> 112 }
            val areaOffset = when (item.tag) { 2 -> 28; 3 -> 63; else -> 44 }
            val product = bits.unsigned(productOffset, 14) ?: return@flatMap emptyList()
            val area = bits.unsigned(areaOffset, if (item.tag == 2) 4 else 6) ?: return@flatMap emptyList()
            val start = bits.unsigned(validity, 14) ?: return@flatMap emptyList()
            val startMinute = bits.unsigned(validity + 14, 11) ?: return@flatMap emptyList()
            val end = bits.unsigned(validity + 25, 14) ?: return@flatMap emptyList()
            val endMinute = bits.unsigned(validity + 39, 11) ?: return@flatMap emptyList()
            if (product == 0L || (start == 0L && end == 0L)) return@flatMap emptyList()
            val from = if (start == 0L && startMinute == 0L) null else localTime(1997, start.toInt(), startMinute.toInt(), "Europe/Helsinki")
            val to = if (end == 0L && endMinute == 0L) null else localTime(1997, end.toInt(), endMinute.toInt(), "Europe/Helsinki")
            if (from != null && to != null && to < from) return@flatMap emptyList()
            listOf(Pass(format.family, "Value ticket", product.toInt(), area.toInt(), from, to))
        }
    }

    fun localTime(year: Int, day: Int, minute: Int, zone: String): Long? {
        if (day < 0 || minute !in 0..1439) return null
        return runCatching {
            val local = LocalDate.of(year, 1, 1).plusDays(day.toLong()).atTime(minute / 60, minute % 60)
            val offsets = ZoneId.of(zone).rules.getValidOffsets(local)
            if (offsets.size == 1) local.toEpochSecond(offsets.single()) else null
        }.getOrNull()
    }

    private fun hex(data: ByteArray) = data.joinToString("") { "%02X".format(it.toInt() and 255) }
    private class Bits(private val data: ByteArray) {
        fun unsigned(start: Int, length: Int): Long? {
            if (start < 0 || length !in 1..63 || start + length > data.size * 8) return null
            return (start until start + length).fold(0L) { value, bit ->
                (value shl 1) or ((data[bit / 8].toInt() ushr (7 - bit % 8)) and 1).toLong()
            }
        }
        fun signed(start: Int, length: Int): Long? = unsigned(start, length)?.let {
            if ((it and (1L shl (length - 1))) == 0L) it else it - (1L shl length)
        }
    }
}
