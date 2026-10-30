package ad.neko.cardbal.android.nfc

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

/** Independently implemented public Calypso/EN1545 wire formats. No keys, sessions,
 * writes, holder personal-data decoding, GPL implementation or captures.
 * Facts: Metrodroid b910c1806fd86aa545223baf1d21fc5afe68eee2;
 * Cardpeek de8cee209b870f3d7aa1c6bd55e84738765dc1e6 c250n64/c250n901/c56n1.
 */
internal object CalypsoProtocol {
    enum class Network(val id: Int, val family: String, val currency: String?, val timeZone: String) {
        Generic(0, "Calypso", null, "UTC"), Intercode(1, "Calypso", "EUR", "Europe/Paris"),
        Navigo(2, "Navigo", "EUR", "Europe/Paris"), Opus(3, "OPUS", "CAD", "America/Toronto"),
        Mobib(4, "MOBIB", "EUR", "Europe/Brussels"), RavKav(5, "Rav-Kav", "ILS", "Asia/Jerusalem")
    }
    data class Record(val sfi: Int, val number: Int, val payload: ByteArray)
    data class Contract(val slot: Int, val productCode: Long?, val providerCode: Long?, val serialNumber: String?, val soldAt: String?,
        val validFrom: String?, val validUntil: String?, val counter: Long?,
        val remainingTrips: Long?, val balanceMinor: Long?, val currency: String?)
    data class History(val network: Network, val timestampMillis: Long?, val amountMinor: Long?,
        val currency: String?, val description: String, val operatorCode: String?, val routeCode: String?,
        val stationCode: String?, val eventCode: Int?, val resultCode: Int?, val counter: Long?)
    data class ReadResult(val network: Network, val selectedAid: String, val serial: String?,
        val balanceMinor: Long?, val remainingTrips: Long?, val fields: List<Pair<String, String>>,
        val records: List<Record>, val contracts: List<Contract>, val rawHistories: List<String>) {
        val family get() = network.family
        val currency get() = network.currency
        val timeZone get() = network.timeZone
        val hasDecodedData get() = network != Network.Generic && (contracts.isNotEmpty() || records.any {
            CalypsoProtocol.encodeRecord(network,it)?.let(CalypsoProtocol::parseHistory) != null
        })
        val balanceText: String? get() = balanceMinor?.let { "${currency} ${java.math.BigDecimal.valueOf(it, 2).toPlainString()}" }
            ?: remainingTrips?.let { "$it trips" }
    }
    val selectionAids = listOf("A0000004040125090101", "315449432E494341", "334D54522E494341", "A000000291", "A000000404")
    private val magic = byteArrayOf(0x43, 0x59, 0x50, 1)

    private class Bits(val bytes: ByteArray, var position: Int = 0) {
        fun take(count: Int): Long {
            require(count in 0..63 && position + count <= bytes.size * 8)
            var value = 0L
            repeat(count) { value = (value shl 1) or ((bytes[position / 8].toInt() ushr (7 - position % 8)) and 1).toLong(); position++ }
            return value
        }
        fun skip(count: Int) { require(count >= 0 && position + count <= bytes.size * 8); position += count }
    }
    private sealed interface Field {
        data class Value(val name: String, val width: Int): Field
        data class Group(val children: List<Field>, val optional: Boolean): Field
    }
    // A small, bounded schema interpreter separates factual bit layouts from
    // parsing logic. Square groups have one LSB-first presence bit per child.
    private fun schema(text: String): Field.Group {
        var offset = 0
        fun group(close: Char?, optional: Boolean): Field.Group {
            val fields = mutableListOf<Field>()
            while (offset < text.length) {
                when (val char = text[offset]) {
                    ',', ' ' -> offset++
                    ']', ')' -> { require(char == close); offset++; return Field.Group(fields, optional) }
                    '[', '(' -> { offset++; fields.add(group(if (char == '[') ']' else ')', char == '[')) }
                    else -> {
                        val start = offset
                        while (offset < text.length && text[offset] != ':') offset++
                        require(offset < text.length)
                        val name = text.substring(start, offset++)
                        val widthStart = offset
                        while (offset < text.length && text[offset].isDigit()) offset++
                        fields.add(Field.Value(name, text.substring(widthStart, offset).toInt()))
                    }
                }
            }
            require(close == null)
            return Field.Group(fields, optional)
        }
        return group(null, false)
    }
    private fun parse(bytes: ByteArray, name: String): Map<String, Long>? = runCatching {
        require(bytes.isNotEmpty() && bytes.size <= 256)
        val bits = Bits(bytes); val values = mutableMapOf<String, Long>()
        fun read(field: Field) {
            when (field) {
                is Field.Value -> if (field.name == "_") bits.skip(field.width) else values[field.name] = bits.take(field.width)
                is Field.Group -> {
                    val mask = if (field.optional) bits.take(field.children.size) else -1L
                    field.children.forEachIndexed { index, child -> if (!field.optional || mask and (1L shl index) != 0L) read(child) }
                }
            }
        }
        read(schema(schemas.getValue(name))); values.toMap()
    }.getOrNull()
    private fun at(data: ByteArray, bit: Int, count: Int): Long? = runCatching { Bits(data, bit).take(count) }.getOrNull()

    fun identify(environment: ByteArray): Network {
        if (environment.size != 29 || environment.all { it == 0.toByte() || it == 0xFF.toByte() }) return Network.Generic
        val rav = at(environment, 3, 20)
        if (rav == 0x37602L || rav == 0x37603L) return if (parse(environment, "envRav") != null) Network.RavKav else Network.Generic
        val id = at(environment, 13, 24)
        if (id == 0x056001L) {
            val version = at(environment,0,6) ?: return Network.Generic
            return if (version <= 4 && parse(environment, if (version <= 2) "envMobibOld" else "envMobibNew") != null) Network.Mobib else Network.Generic
        }
        val parsed = parse(environment, "env") ?: return Network.Generic
        if (parsed["network"] != id) return Network.Generic // network presence bit is mandatory
        return when (id) { 0x250901L -> Network.Navigo; 0x124001L -> Network.Opus; else -> if (id != null && id ushr 12 == 0x250L) Network.Intercode else Network.Generic }
    }
    private fun validRecord(record: Record): Boolean = record.sfi in 1..30 && record.number in 1..255 && record.payload.size in 1..256
    fun encodeRecord(network: Network, record: Record): ByteArray? {
        if (!validRecord(record)) return null
        return magic + byteArrayOf(network.id.toByte(), record.sfi.toByte(), record.number.toByte(),
            (record.payload.size ushr 8).toByte(), record.payload.size.toByte()) + record.payload
    }
    private fun decodeRecord(data: ByteArray): Pair<Network, Record>? {
        if (data.size < 10 || !data.copyOfRange(0, 4).contentEquals(magic)) return null
        val network = Network.entries.singleOrNull { it.id == (data[4].toInt() and 255) } ?: return null
        val length = ((data[7].toInt() and 255) shl 8) or (data[8].toInt() and 255)
        if (data.size != 9 + length) return null
        val record = Record(data[5].toInt() and 255, data[6].toInt() and 255, data.copyOfRange(9, data.size))
        return if (validRecord(record)) network to record else null
    }
    fun mergeHistory(records: List<String>): List<String> = records.distinctBy { raw ->
        val bytes = if (raw.length % 2 == 0 && raw.all { it in '0'..'9' || it in 'A'..'F' || it in 'a'..'f' })
            raw.chunked(2).map { it.toInt(16).toByte() }.toByteArray() else null
        val pair = bytes?.let(::decodeRecord)
        if (bytes != null && pair != null && parseHistory(bytes) != null) {
            val (network,record) = pair
            val logicalFile = if (network == Network.Mobib && record.sfi == 23) 8 else record.sfi
            "E:${network.id}:$logicalFile:" + record.payload.joinToString("") { "%02X".format(it) }
        } else "R:" + raw.uppercase()
    }
    private fun date(day: Long?): String? = day?.takeIf { it in 1..16382 }?.let { LocalDate.of(1997, 1, 1).plusDays(it).toString() }
    private fun timestamp(day: Long?, minute: Long?, zone: String): Long? = runCatching {
        require(day != null && day in 1..16382 && minute != null && minute in 0..1439)
        val local = LocalDate.of(1997, 1, 1).plusDays(day).atStartOfDay().plusMinutes(minute)
        val offsets = ZoneId.of(zone).rules.getValidOffsets(local)
        if (offsets.size != 1) null else local.toInstant(offsets.single()).toEpochMilli()
    }.getOrNull()
    fun parseHistory(envelope: ByteArray): History? {
        val (network, record) = decodeRecord(envelope) ?: return null
        if (network == Network.Generic || record.sfi !in listOf(8, 23, 29) || record.payload.size != 29 || record.payload.all { it == 0.toByte() }) return null
        if (record.sfi == 23 && network != Network.Mobib) return null
        if (record.sfi == 29 && network !in listOf(Network.Intercode, Network.Navigo)) return null
        val version = at(record.payload, 0, 6) ?: return null
        val layout = when (network) {
            Network.Opus -> "eventOpus"; Network.RavKav -> "eventRav"
            Network.Mobib -> if (version <= 2) "eventMobibOld" else if (version <= 4) "eventMobibNew" else return null
            else -> "eventIntercode"
        }
        val values = parse(record.payload, layout) ?: return null
        if (network == Network.Intercode && values["network"] !in listOf(0x250064L,0x250901L,0x250916L,0x250920L,0x250921L)) return null
        if (network == Network.Navigo && values["network"] != null && values["network"] != 0x250901L) return null
        val code = values["code"]?.toInt(); val kind = code?.and(15)
        val label = when (kind) { 1, 6 -> "Entry"; 2, 7 -> "Exit"; 4 -> "Inspection"; 9 -> "Cancelled event"; 13 -> "Top-up"; else -> "Travel event" }
        val millis = if (network == Network.RavKav) values["seconds"]?.takeIf { it in 1..0x3FFFFFFE }?.let {
            LocalDateTime.of(1997, 1, 1, 0, 0).toInstant(ZoneOffset.UTC).toEpochMilli() + it * 1000
        } else timestamp(values["day"], values["minute"], network.timeZone)
        // An invalid/ambiguous wall time remains raw data, not a guessed event.
        if (millis == null) return null
        val result = values["result"]?.toInt()
        val price = values["price"]?.takeIf { result == null || result == 0 }
        val amount = if (kind == 13) price else if (kind in listOf(1, 2, 6, 7)) price?.let { -it } else null
        return History(network, millis, amount, network.currency,
            if (result != null && result != 0) "Rejected $label" else label,
            values["provider"]?.toString(), values["route"]?.toString(), values["station"]?.toString(), code, result, values["counter"])
    }
    private fun counter(records: List<Record>, slot: Int): Long? {
        records.firstOrNull { it.sfi == 25 && it.number == 1 }?.payload?.let { data ->
            val offset = (slot - 1) * 3
            if (offset + 3 <= data.size) return at(data, offset * 8, 24)
        }
        if (slot in 1..4) return records.firstOrNull { it.sfi == 9 + slot && it.number == 1 }?.payload?.let { at(it, 0, 24) }
        return null
    }
    private fun contractTypes(network: Network, data: ByteArray?): Map<Int, Int> {
        if (network !in listOf(Network.Navigo, Network.Intercode) || data == null) return emptyMap()
        return runCatching {
            val bits = Bits(data); val count = bits.take(4).toInt(); val output = mutableMapOf<Int, Int>()
            repeat(count) {
                val mask = bits.take(3).toInt()
                if (mask and 1 != 0) bits.skip(24)
                val tariff = if (mask and 2 != 0) bits.take(16).toInt() else null
                val slot = if (mask and 4 != 0) bits.take(5).toInt() else null
                if (slot != null && slot in 1..8 && tariff != null) output[slot] = (tariff ushr 4) and 255
            }; output.toMap()
        }.getOrElse { emptyMap() }
    }
    fun contracts(network: Network, records: List<Record>): List<Contract> {
        if (network == Network.Generic) return emptyList()
        val types = contractTypes(network, records.firstOrNull { it.sfi == 30 && it.number == 1 }?.payload)
        return records.filter { it.sfi == 9 && it.payload.size == 29 && !it.payload.all { b -> b == 0.toByte() } && !it.payload.all { b -> b == 0xFF.toByte() } }.mapNotNull { record ->
            val version = at(record.payload, 0, 6) ?: return@mapNotNull null
            val layout = when (network) {
                Network.Opus -> "contractOpus"; Network.RavKav -> "contractRav"
                Network.Mobib -> if (version <= 3) "contractMobibOld" else if (version == 4L) "contractMobibNew" else return@mapNotNull null
                else -> when (types[record.number]) { 0x46 -> "contract46"; 0x20 -> "contract20"; 0xFF -> "contractFF"; else -> "commonContract" }
            }
            val values = parse(record.payload, layout) ?: return@mapNotNull null
            if (values["network"] != null && ((network == Network.Intercode && values.getValue("network") ushr 12 != 0x250L) ||
                (network == Network.Navigo && values["network"] != 0x250901L))) return@mapNotNull null
            val product = values["product"] ?: return@mapNotNull null
            if (product == 0L) return@mapNotNull null
            val count = counter(records, record.number)
            val remaining = when (network) {
                Network.Opus -> if ((values["end"] ?: 0) == 0L) count else null
                Network.RavKav -> if ((product ushr 6) and 7 == 2L) count else null
                Network.Mobib -> if ((product ushr 10) and 7 != 4L) count else null
                Network.Intercode -> count?.takeIf { product == 191L && types[record.number] == 0x46 && it <= 255 }
                Network.Navigo -> when { (values["debit"] ?: 0) > 0 && (values["sold"] ?: 0) > 0 -> count?.div(values.getValue("debit"));
                    (values["journeys"] ?: 0) > 0 -> count?.ushr(18); else -> null }
                else -> null
            }
            val balance = if (network == Network.RavKav && (product ushr 6) and 7 == 3L) count else null
            val start = date(values["start"]); val end = date(values["end"])
            if (start != null && end != null && start > end) return@mapNotNull null
            Contract(record.number, product, values["provider"], values["serial"]?.toString(), date(values["sale"]), start, end, count, remaining, balance, network.currency)
        }
    }
    private fun fields(network: Network, records: List<Record>, contracts: List<Contract>): List<Pair<String, String>> {
        val output = mutableListOf("Network" to network.family)
        val env = records.firstOrNull { it.sfi == 7 && it.number == 1 }?.payload
        val layout = when (network) { Network.RavKav -> "envRav"; Network.Mobib -> if ((env?.let { at(it,0,6) } ?: 63) <= 2) "envMobibOld" else "envMobibNew"; else -> "env" }
        if (env != null && network != Network.Generic) date(parse(env, layout)?.get("expiry"))?.let { output.add("Card Valid Until" to it) }
        contracts.forEach { contract ->
            val p = "Contract ${contract.slot}"
            output.add("$p Product" to contract.productCode.toString())
            if (network == Network.Intercode) output.add("Ticket" to "Product ${contract.productCode}")
            contract.serialNumber?.let { output.add("$p Serial Number" to it) }; contract.soldAt?.let { output.add("$p Sold At" to it) }
            contract.providerCode?.let { output.add("$p Provider Code" to it.toString()) }
            contract.validFrom?.let { output.add("$p Valid From" to it) }; contract.validUntil?.let { output.add("$p Valid Until" to it) }
            contract.remainingTrips?.let { output.add("$p Remaining Trips" to it.toString()) }
            contract.balanceMinor?.let { output.add("$p Balance" to "${contract.currency} ${java.math.BigDecimal.valueOf(it,2).toPlainString()}") }
            contract.counter?.let { output.add("$p Raw Counter" to it.toString()) }
        }
        return output
    }
    private fun response(command: ByteArray, exchange: (ByteArray) -> ByteArray): ByteArray? {
        var reply = runCatching { exchange(command) }.getOrNull() ?: return null
        if (reply.size == 2 && reply[0] == 0x6C.toByte()) {
            val retry = if (command.size >= 5 && command[1] == 0xA4.toByte() && command.size == 5 + (command[4].toInt() and 255)) {
                command + byteArrayOf(reply[1])
            } else command.clone().also { it[it.lastIndex] = reply[1] }
            reply = runCatching { exchange(retry) }.getOrNull() ?: return null
        }
        if (reply.size < 2 || reply[reply.size - 2] != 0x90.toByte() || reply.last() != 0.toByte()) return null
        return reply.dropLast(2).toByteArray()
    }
    fun read(exchange: (ByteArray) -> ByteArray): ReadResult? {
        for (aid in selectionAids) {
            val name = aid.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val select = byteArrayOf(0, 0xA4.toByte(), 4, 0, name.size.toByte()) + name + byteArrayOf(0)
            if (response(select, exchange) == null) continue
            for (cla in listOf(0x94, 0x00)) {
                // SELECT ticketing directory2000; this is not OPEN SECURE SESSION.
                response(byteArrayOf(cla.toByte(), 0xA4.toByte(), 8, 0, 2, 0x20, 0), exchange)
                fun read(sfi: Int, number: Int): ByteArray? {
                    response(byteArrayOf(cla.toByte(), 0xB2.toByte(), number.toByte(), ((sfi shl 3) or 4).toByte(), 0x1D), exchange)?.let { return it }
                    val file = mapOf(2 to 0x0002, 7 to 0x2001, 8 to 0x2010, 9 to 0x2020, 10 to 0x202A,
                        11 to 0x202B, 12 to 0x202C, 13 to 0x202D, 25 to 0x2069, 29 to 0x2040, 30 to 0x2050)[sfi] ?: return null
                    val path = (if (sfi == 2) byteArrayOf() else byteArrayOf(0x20, 0)) + byteArrayOf((file ushr 8).toByte(), file.toByte())
                    if (response(byteArrayOf(cla.toByte(), 0xA4.toByte(), 8, 0, path.size.toByte()) + path, exchange) == null) return null
                    return response(byteArrayOf(cla.toByte(), 0xB2.toByte(), number.toByte(), 4, 0x1D), exchange)
                }
                val environment = read(7, 1)?.takeIf { it.size == 29 && !it.all { b -> b == 0.toByte() || b == 0xFF.toByte() } } ?: continue
                val network = identify(environment)
                val records = mutableListOf(Record(7, 1, environment))
                val targets = listOf(2 to 1, 8 to 16, 9 to 8, 10 to 1, 11 to 1, 12 to 1, 13 to 1, 25 to 1, 29 to 4, 30 to 1) +
                    if (network == Network.Mobib) listOf(23 to 16) else emptyList()
                for ((sfi, maximum) in targets) {
                    for (number in 1..maximum) {
                        val payload = read(sfi, number)?.takeIf { it.size in 1..256 } ?: break
                        if ((payload.all { it == 0.toByte() } && sfi !in listOf(10,11,12,13,25)) || payload.all { it == 0xFF.toByte() }) break
                        records.add(Record(sfi, number, payload))
                    }
                }
                val contracts = contracts(network, records)
                val money = contracts.mapNotNull { it.balanceMinor }.singleOrNull()
                val remaining = contracts.mapNotNull { it.remainingTrips }.firstOrNull { it > 0 } ?: contracts.mapNotNull { it.remainingTrips }.firstOrNull()
                val icc = records.firstOrNull { it.sfi == 2 && it.number == 1 }?.payload
                val serial = if (network in listOf(Network.Navigo, Network.Opus) && icc != null) {
                    val value = at(icc, 128, 32)?.takeIf { it != 0L && it != 0xFFFFFFFFL } ?: at(icc, 0, 32)?.takeIf { it != 0L && it != 0xFFFFFFFFL }
                    value?.toString()
                } else null
                return ReadResult(network, aid, serial, money, remaining, fields(network, records, contracts), records, contracts,
                    records.mapNotNull { encodeRecord(network,it)?.joinToString("") { b -> "%02X".format(b) } })
            }
        }
        return null
    }
    private val schemas = mapOf(
        "env" to "version:6,[network:24,issuer:8,expiry:14,_:11,_:16,_:32,_:1]",
        "envRav" to "version:3,network:20,_:26,issued:14,expiry:14",
        "envMobibOld" to "version:6,_:7,network:24,_:9,expiry:14",
        "envMobibNew" to "version:6,_:7,network:24,_:5,expiry:14",
        "commonContract" to "[provider:8,product:16,serial:32,passenger:8,[start:14,end:14],status:8,_:0]",
        "contract46" to "[provider:8,product:16,serial:32,passenger:8,[start:14,end:14],status:8,[(_:16,_:16,_:16),(_:16,_:16),zones:16,(sale:14,_:16,_:8),(_:11,price:16,_:1),_:6,(_:14,_:6),(sold:8,debit:5),_:4,_:5,startTime:11,endTime:11,_:14,_:14,_:28,journeys:16,_:32]]",
        "contract20" to "[provider:8,product:16,serial:32,passenger:8,[start:14,end:14],status:8,[(_:16,_:16,_:16),(_:16,_:16),zones:16,(sale:14,_:16,_:8),(_:11,price:16,_:1),_:6,(_:14,_:6),(sold:8,debit:5),_:4,_:5]]",
        "contractFF" to "[network:24,provider:8,product:16,serial:32,[_:6,_:32],[_:8,_:8],_:6,_:32,_:11,_:16,price:16,_:16,[_:11,_:11,_:8,_:8,_:8,_:16,_:16],[start:14,startTime:11,end:14,endTime:11,duration:8,_:14,zones:8,journeys:16,_:16],[_:16,_:16,_:16,_:8,_:16,_:16,_:16,_:8],[sale:14,_:11,_:8,_:16],status:8,_:16,_:16,_:0]",
        "contractOpus" to "_:3,[provider:8,product:16,[start:14,end:14],(_:17,sale:14,_:11,_:36,status:8,_:36)]",
        "contractRav" to "version:3,start:14,provider:8,product:11,sale:14,_:12,_:10,_:1,[_:5,_:5,_:6,end:14,duration:8,_:32,_:6,_:32,_:32]",
        "contractMobibOld" to "version:6,_:21,product:14,sale:14,_:48,price:16,_:113",
        "contractMobibNew" to "version:6,_:19,product:14,_:50,price:16,_:6,[_:5,_:5,sale:14,(_:2,duration:8),_:8],_:24",
        "eventIntercode" to "day:14,minute:11,[_:8,network:24,code:8,result:8,provider:8,_:8,counter:24,_:16,station:16,_:8,_:16,route:16,_:8,_:16,_:16,_:8,_:5,_:240,_:16,_:8,_:16,_:16,_:16,price:16,unit:16,contract:5,_:16,[_:14,_:11,_:1,_:2,_:2]]",
        "eventOpus" to "day:14,minute:11,_:19,[_:8,_:8,provider:8,_:16,route:16,_:16,_:16,contract:5,[_:14,_:11,_:1,_:4,_:4,_:4,_:4]]",
        "eventRav" to "version:3,provider:8,contract:4,code:8,seconds:30,_:1,_:30,_:32,[station:16,route:16,_:8,_:12,_:14,_:4,_:8],[(_:10,_:8,price:16),_:32,_:32]",
        "eventMobibOld" to "version:6,day:14,minute:11,_:21,_:5,_:14,_:12,route:16,provider:5,station:17,_:10,_:7,counter:24,_:24,_:14,_:11,_:21",
        "eventMobibNew" to "version:6,day:14,minute:11,_:31,[(_:4,_:12),route:16,_:16,_:16,(provider:5,station:17,_:10)],[counter:24,_:16,_:8,_:16,(_:14,_:11),_:16],_:21",
    )
}
