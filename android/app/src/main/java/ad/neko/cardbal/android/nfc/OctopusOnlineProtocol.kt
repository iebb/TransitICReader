package ad.neko.cardbal.android.nfc

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.math.BigDecimal
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID

internal class OctopusProtocolException : IOException("Invalid or incomplete Octopus enquiry")

internal object OctopusOcap {
    const val MAX_BODY = 1_048_576
    data class Instruction(val type: Int, val id: Int, val opcode: Int, val operands: List<Int>)
    data class Message(val state: Int, val instructions: List<Instruction>, val records: Map<Int, ByteArray>)
    class Cursor(val bytes: ByteArray) {
        var position = 0
        fun take(count: Int): ByteArray {
            if (count < 0 || count > bytes.size - position) throw OctopusProtocolException()
            return bytes.copyOfRange(position, position + count).also { position += count }
        }
        fun byte() = take(1)[0].toInt() and 255
        fun signedByte() = take(1)[0].toInt()
        fun word() = (byte() shl 8) or byte()
        fun signedWord() = word().toShort().toInt()
        fun count() = signedWord().also { if (it < 0) throw OctopusProtocolException() }
    }
    fun word(value: Int) = byteArrayOf((value ushr 8).toByte(), value.toByte())
    fun checksum(bytes: ByteArray): Int {
        var sum = 0
        for (index in bytes.indices step 2) {
            sum += (bytes[index].toInt() and 255) shl 8
            if (index + 1 < bytes.size) sum += bytes[index + 1].toInt() and 255
        }
        return -sum and 65535
    }
    fun outbound(state: Int, payload: ByteArray): ByteArray {
        var frame = "OCAP".toByteArray() + byteArrayOf(0, 0, 1, 0, state.toByte()) + payload
        val length = frame.size - 6
        if (length > 32767) throw OctopusProtocolException()
        frame += word(checksum(frame))
        frame[4] = length.toByte()
        frame[5] = (length ushr 8).toByte()
        return frame
    }
    fun deviceInfo(): ByteArray {
        var payload = "DINF".toByteArray() + word(2)
        for ((id, type, name) in listOf(Triple(0x13, 1, "IOS_NFC"), Triple(3, 2, "APPLET"))) {
            payload += byteArrayOf(id.toByte(), type.toByte()) + word(name.length) + name.toByteArray()
        }
        return outbound(1, payload)
    }
    fun reply(data: ByteArray): ByteArray {
        if (data.size > 32767) throw OctopusProtocolException()
        return outbound(2, "RPLY".toByteArray() + byteArrayOf(0) + word(data.size) + data)
    }
    fun parse(data: ByteArray): List<Message> {
        if (data.isEmpty() || data.size > MAX_BODY) throw OctopusProtocolException()
        val cursor = Cursor(data)
        return buildList {
            while (cursor.position < data.size) {
                val start = cursor.position
                if (!cursor.take(4).contentEquals("OCAP".toByteArray())) throw OctopusProtocolException()
                cursor.count(); cursor.take(2)
                val state = cursor.byte()
                cursor.take(4)
                val instructions = List(cursor.count()) {
                    val type = cursor.signedByte()
                    val id = cursor.signedWord()
                    val opcode = cursor.signedByte()
                    val count = cursor.signedByte()
                    if (count < 0) throw OctopusProtocolException()
                    Instruction(type, id, opcode, List(count) { cursor.signedByte() })
                }
                cursor.take(4)
                val records = mutableMapOf<Int, ByteArray>()
                repeat(cursor.count()) {
                    val id = cursor.signedWord()
                    val value = cursor.take(cursor.count())
                    if (records.put(id, value) != null) throw OctopusProtocolException()
                }
                val end = cursor.position
                if (cursor.word() != checksum(data.copyOfRange(start, end))) throw OctopusProtocolException()
                add(Message(state, instructions, records))
            }
        }
    }
}

internal class OctopusEnquiryVm(
    private val inputs: Map<String, String>,
    private val deadlineNanos: Long,
    private val allowsCardUpdates: Boolean = false,
    private val exchange: (ByteArray) -> ByteArray,
) {
    companion object {
        /** FeliCa commands that only read, authenticate or describe the card, in both the DES and the
         *  AES (V2) command sets. Polling (0x00) is checked separately by the relay. Without consent,
         *  any other command is a possible card update and is skipped, not sent to the card. */
        val READ_ONLY_CARD_OPCODES = setOf(
            0x02, // Request Service
            0x04, // Request Response
            0x06, // Read Without Encryption
            0x0A, // Search Service Code
            0x0C, // Request System Code
            0x0E, // Request Block Information
            0x10, // Authentication1 (DES)
            0x12, // Authentication2
            0x14, // Read
            0x1A, // Request Code List
            0x1E, // Request Block Information Ex
            0x22, // Get Container Issue Information
            0x24, // Get Area Information
            0x28, // Get Node Property
            0x2E, // Get Container Property
            0x32, // Request Service V2
            0x34, // Internal Authenticate And Read
            0x38, // Get System Status
            0x3A, // Request Product Information
            0x3C, // Request Specification Version
            0x40, // Authentication1 V2 (AES)
            0x42, // Authentication2 V2
            0x44, // Read V2
        )
        /** An authenticated read in either generation: Authentication1, Authentication2 and Read. */
        val AUTHENTICATED_READ_OPCODES = listOf(setOf(0x10, 0x40), setOf(0x12, 0x42), setOf(0x14, 0x44))

        /** True when a command outside polling and the read-only set reached the card. */
        fun mayHaveUpdatedCard(opcodes: Set<Int>): Boolean = !READ_ONLY_CARD_OPCODES.containsAll(opcodes - 0x00)
    }
    val serverData = mutableMapOf<Int, ByteArray>()
    val cardOpcodes = mutableSetOf<Int>()
    var skippedCardUpdates = 0
        private set
    private var cardCommands = 0
    fun run(message: OctopusOcap.Message): ByteArray {
        val registers = Array(16) { byteArrayOf() }
        fun register(index: Int): Int = index.also { if (it !in 0..15) throw OctopusProtocolException() }
        var pc = 0
        var steps = 0
        val counts = mapOf(1 to 2, 2 to 2, 3 to 2, 4 to 3, 5 to 4, 0x11 to 0, 0x12 to 3)
        while (pc < message.instructions.size) {
            if (++steps > 4096 || System.nanoTime() >= deadlineNanos) throw OctopusProtocolException()
            val instruction = message.instructions[pc++]
            val op = instruction.operands
            if (instruction.type != 1 || counts[instruction.opcode] != op.size) throw OctopusProtocolException()
            if (instruction.opcode == 0x11) break
            if (instruction.opcode == 0x12) {
                if (registers[register(op[1])].contentEquals(registers[register(op[2])])) {
                    pc = message.instructions.indexOfFirst { it.id == op[0] }
                    if (pc < 0) throw OctopusProtocolException()
                }
                continue
            }
            val dst = register(op[0])
            registers[dst] = when (instruction.opcode) {
                1 -> execute(registers[register(op[1])])
                2 -> message.records[op[1]] ?: throw OctopusProtocolException()
                3 -> registers[register(op[1])]
                4 -> registers[register(op[1])] + registers[register(op[2])]
                5 -> {
                    val source = registers[register(op[1])]
                    if (op[2] < 0 || op[3] < 0 || op[2] > source.size || op[3] > source.size - op[2]) throw OctopusProtocolException()
                    source.copyOfRange(op[2], op[2] + op[3])
                }
                else -> throw OctopusProtocolException()
            }
            if (registers[dst].size > OctopusOcap.MAX_BODY) throw OctopusProtocolException()
        }
        return registers[15]
    }
    private fun execute(data: ByteArray): ByteArray {
        val packet = OctopusOcap.Cursor(data)
        if (!packet.take(4).contentEquals("DMSG".toByteArray())) throw OctopusProtocolException()
        packet.take(6)
        val device = packet.byte()
        val sequence = packet.byte()
        val commandData = packet.take(packet.word())
        if (packet.position != data.size) throw OctopusProtocolException()
        val response = when (device) {
            1 -> if (commandData.isEmpty()) byteArrayOf() else {
                var command = commandData.copyOfRange(1, commandData.size)
                if (command.isNotEmpty() && (command[0].toInt() and 255) == command.size) command = command.copyOfRange(1, command.size)
                if (command.isEmpty() || command.size > 253 || cardCommands >= 256) throw OctopusProtocolException()
                val opcode = command[0].toInt() and 255
                if (!allowsCardUpdates && opcode != 0 && opcode !in READ_ONLY_CARD_OPCODES) {
                    // Skip the update: the card never sees it and the service gets no card reply.
                    skippedCardUpdates++
                    cardCommands++
                    byteArrayOf()
                } else {
                    val result = exchange(command)
                    if (result.size !in 2..255 || (result[0].toInt() and 255) != result.size ||
                        (result[1].toInt() and 255) != (opcode + 1) % 256) throw OctopusProtocolException()
                    cardOpcodes += opcode
                    cardCommands++
                    result
                }
            }
            2 -> {
                val command = OctopusOcap.Cursor(commandData)
                val result = when (command.byte()) {
                    7 -> {
                        val entries = buildList {
                            repeat(command.count()) {
                                val keyBytes = command.take(command.byte())
                                if (keyBytes.any { it < 0 }) throw OctopusProtocolException()
                                inputs[keyBytes.toString(Charsets.US_ASCII)]?.let { value ->
                                    val bytes = value.toByteArray(Charsets.US_ASCII)
                                    if (bytes.size > 32767) throw OctopusProtocolException()
                                    add(byteArrayOf(keyBytes.size.toByte()) + keyBytes + OctopusOcap.word(bytes.size) + bytes)
                                }
                            }
                        }
                        byteArrayOf(10, 0) + OctopusOcap.word(entries.size) + entries.fold(byteArrayOf()) { a, b -> a + b }
                    }
                    5 -> {
                        val updates = mutableMapOf<Int, ByteArray>()
                        repeat(command.count()) {
                            val key = command.signedWord()
                            updates[key] = command.take(command.count())
                        }
                        serverData.putAll(updates)
                        byteArrayOf(6, 0)
                    }
                    1 -> { command.take(command.bytes.size - command.position); byteArrayOf() }
                    else -> throw OctopusProtocolException()
                }
                if (command.position != commandData.size) throw OctopusProtocolException()
                result
            }
            else -> throw OctopusProtocolException()
        }
        if (response.size > 32757) throw OctopusProtocolException()
        return "DMSG".toByteArray() + OctopusOcap.word(response.size + 10) + byteArrayOf(1, 0, 0, 2, device.toByte(), sequence.toByte()) +
            OctopusOcap.word(response.size + 2) + response + byteArrayOf(0x90.toByte(), 0)
    }
}

internal data class OctopusCardMetadata(val cardNumber: String, val offset: Int, val serviceStatus: String) {
    val isValid get() = cardNumber.matches(Regex("[0-9]{8,12}")) && cardNumber.any { it != '0' } && offset in setOf(350, 500)
    companion object {
        fun calibrated(result: ByteArray, rawValue: Long, opcodes: Set<Int>): OctopusCardMetadata? = runCatching {
            if (OctopusEnquiryVm.AUTHENTICATED_READ_OPCODES.any { step -> step.none { it in opcodes } }) return null
            val card = Json.parseToJsonElement(result.toString(Charsets.UTF_8)).jsonObject.getValue("cardDataVO").jsonObject
            val balance = card.getValue("balance").jsonPrimitive.content.toBigDecimal()
            val short = card["octopusNo"]?.jsonPrimitive?.content?.filter { it in '0'..'9' }
            val long = card["octopusNoLong"]?.jsonPrimitive?.content?.toBigIntegerOrNull()?.toString()
            val number = long ?: short ?: return null
            if (short != null && short != number) return null
            val offset = BigDecimal.valueOf(rawValue).subtract(balance.multiply(BigDecimal.TEN)).intValueExact()
            val status = card.getValue("status").jsonPrimitive.content
            OctopusCardMetadata(number, offset, status).takeIf { it.isValid && status.isNotBlank() }
        }.getOrNull()
    }
}

internal class OctopusEnquiryClient(
    private val baseUrl: String,
    private val allowLoopback: Boolean = false,
    private val timeoutMillis: Int = REQUEST_TIMEOUT_MILLIS,
) {
    companion object {
        /** Each request may take up to this long, within the overall 25-second deadline. */
        const val REQUEST_TIMEOUT_MILLIS = 10_000
    }
    private val deviceId = UUID.randomUUID().toString()
    private var deadlineNanos = 0L
    /** Card updates skipped during the last enquiry, kept even when it fails. */
    var skippedCardUpdates = 0
        private set
    private fun post(path: String, body: ByteArray = byteArrayOf()): ByteArray {
        val remaining = (deadlineNanos - System.nanoTime()) / 1_000_000
        if (remaining <= 0) throw OctopusProtocolException()
        val connection = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = minOf(timeoutMillis.toLong(), remaining).toInt().coerceAtLeast(1)
            connection.readTimeout = connection.connectTimeout
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/ocap")
            connection.setRequestProperty("X-OMA-DeviceID", deviceId)
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            if (connection.responseCode != 200 || connection.contentLengthLong > OctopusOcap.MAX_BODY) throw OctopusProtocolException()
            return connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    if (System.nanoTime() >= deadlineNanos) throw OctopusProtocolException()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > OctopusOcap.MAX_BODY - output.size()) throw OctopusProtocolException()
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally { connection.disconnect() }
    }
    fun enquire(allowsCardUpdates: Boolean = false, exchange: (ByteArray) -> ByteArray): Pair<ByteArray, Set<Int>> {
        val uri = URI(baseUrl)
        if (uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
            !(uri.scheme == "https" || allowLoopback && uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost", "[::1]"))) throw OctopusProtocolException()
        deadlineNanos = System.nanoTime() + 25_000_000_000
        val greeting = post("/index.htm").toString(Charsets.UTF_8)
        val marker = Regex("JSESSIONID=", RegexOption.IGNORE_CASE).find(greeting) ?: throw OctopusProtocolException()
        val sessionId = greeting.substring(marker.range.last + 1)
        if (!sessionId.matches(Regex("[A-Za-z0-9._~-]{1,256}"))) throw OctopusProtocolException()
        val path = "/service.htm;jsessionid=$sessionId"
        // The recovered ordinary-enquiry protocol uses this compatibility identity
        // on both transports; it is independent of the CardBal app version.
        val config = "APP_TYPE=0&APP_HASH=AZdOKmzuRKj0x3GPHqlXHgY93q6u9HQUkKC6q%2BlNVGU4&APP=9.40.0&PLATFORM=IOS&phone_id=" +
            deviceId.replace("-", "") + "&LANG=EN_US&TXNTIME_DATEFORMAT=yyyyMMddHHmmss"
        val vm = OctopusEnquiryVm(mapOf("oma_config" to config, "cardid_list_v2" to ""), deadlineNanos, allowsCardUpdates, exchange)
        try {
            var body = post(path, OctopusOcap.deviceInfo())
            repeat(32) {
                var outbound = byteArrayOf()
                val messages = OctopusOcap.parse(body)
                for ((index, message) in messages.withIndex()) {
                    if (message.state == 3) {
                        if (index != messages.lastIndex) throw OctopusProtocolException()
                        return (vm.serverData[1] ?: throw OctopusProtocolException()) to vm.cardOpcodes.toSet()
                    }
                    if (message.state != 2) throw OctopusProtocolException()
                    outbound += OctopusOcap.reply(vm.run(message))
                }
                body = post(path, outbound)
            }
            throw OctopusProtocolException()
        } finally { skippedCardUpdates = vm.skippedCardUpdates }
    }
}
