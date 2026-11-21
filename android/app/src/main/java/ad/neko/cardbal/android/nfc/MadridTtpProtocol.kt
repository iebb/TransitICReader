package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Failures of a Tarjeta Transporte Público read. The card is never asked to change. */
sealed class MadridTtpException(message: String) : Exception(message) {
    class RefusedCommand(val instruction: Int) : MadridTtpException("refused instruction %02X".format(instruction))
    class InvalidResponse : MadridTtpException("invalid service response")
    class Service(val code: String) : MadridTtpException("service status $code")
    class BudgetExceeded : MadridTtpException("round budget exceeded")
}

data class MadridTtpCard(
    val statusCode: String,
    val cardNumber: String? = null,
    val serial: String? = null,
    val cardName: String? = null,
    val group: String? = null,
    val profiles: List<Profile> = emptyList(),
    val issueDate: String? = null,
    val expiryDate: String? = null,
    val blocked: Boolean = false,
    val tickets: List<Ticket> = emptyList(),
    /** The service's card and ticket objects without the list of titles on sale. */
    val summaryJson: String = "{}",
) {
    enum class Kind { PASS, MULTI_TRIP }
    data class Ticket(
        val kind: Kind, val name: String, val zones: String? = null, val soldAt: String? = null,
        val validFrom: String? = null, val validUntil: String? = null, val trips: String? = null, val lastUse: String? = null,
        val expired: Boolean = false,
    )
    data class Profile(val name: String, val validUntil: String?)

    /** A trip count for the card face, only when it cannot be mistaken for another ticket's. */
    val remainingTrips: Int? get() {
        val current = tickets.filterNot { it.expired }
        if (current.any { it.kind == Kind.PASS }) return null
        return current.filter { it.kind == Kind.MULTI_TRIP }.singleOrNull()?.trips?.toIntOrNull()
    }

    val fields: List<Pair<String, String>> get() {
        val output = mutableListOf<Pair<String, String>>()
        fun add(title: String, value: String?) { if (!value.isNullOrEmpty()) output.add(title to value) }
        add("Card Number", cardNumber)
        add("Card Type", cardName)
        add("Profile", group)
        profiles.filter { it.validUntil != expiryDate }.forEach { add(it.name + " Valid Until", it.validUntil) }
        add("Issue Date", issueDate)
        add("Expiry Date", expiryDate)
        if (blocked) add("Status", "Blocked")
        remainingTrips?.let { add("Remaining Trips", it.toString()) }
        val used = mutableMapOf<String, Int>()
        for (ticket in tickets) {
            val count = (used[ticket.name] ?: 0) + 1
            used[ticket.name] = count
            val label = if (count == 1) ticket.name else "${ticket.name} ($count)"
            add("Ticket", label)
            if (ticket.expired) add("$label Status", "Expired")
            add("$label Zones", ticket.zones)
            add("$label Valid From", ticket.validFrom)
            add("$label Valid Until", ticket.validUntil)
            add("$label Remaining Trips", ticket.trips)
            add("$label Sold At", ticket.soldAt)
            add("$label Last Use", ticket.lastUse)
        }
        return output
    }
}

/**
 * Tarjeta Transporte Público of the Consorcio Regional de Transportes de Madrid (CRTM).
 * Every file in its DESFire application needs authentication with keys that only CRTM
 * holds, so the card is read by relaying the commands of CRTM's card-reading service.
 * See docs/decoding/madrid-ttp.md.
 */
object MadridTtpProtocol {
    const val INIT_PATH = "/midd/device/init/conn"
    const val READING_PATH = "/device/front/CardReading"
    /** Wrapped DESFire SELECT APPLICATION 000001, sent before anything reaches the service. */
    val SELECT_APPLICATION = "905A00000300000100".hexToBytes()
    const val MAX_ROUNDS = 16
    const val MAX_COMMANDS_PER_ROUND = 64
    const val MAX_BODY = 262_144
    /** DESFire instructions that only read, select or authenticate. Additional frames (AF)
     *  are relayed only after the card itself asked for one. */
    val READ_INSTRUCTIONS = setOf(
        0x60, 0x5A, 0x0A, 0x1A, 0xAA, 0x71, 0x77, 0xBD, 0xBB, 0x6C,
        0x6F, 0x6A, 0x6D, 0x61, 0x45, 0x64, 0xF5, 0x51, 0x6E,
    )
    private val json = Json { ignoreUnknownKeys = true }

    fun initBody(): ByteArray = buildJsonObject {
        put("language", "en")
        put("timezone", "Europe/Madrid")
    }.toString().toByteArray()

    /** Card updates are never requested: the service is asked for a read only. */
    fun readingBody(rapdu: List<String>?): ByteArray = buildJsonObject {
        put("commandType", "WRAPPED")
        put("opInspection", false)
        if (rapdu != null) putJsonArray("rapdu") { rapdu.forEach { add(JsonPrimitive(it)) } }
        put("salePoint", "010201000005")
        put("titleList", "COMMON")
        put("updateCard", false)
    }.toString().toByteArray()

    /** The APDU of a wrapped read, select or authentication command, or null for anything else. */
    fun permittedCommand(hex: String, afterAdditionalFrame: Boolean): ByteArray? {
        if (hex.length < 10 || hex.length > 600 || hex.length % 2 != 0 || !hex.all { it in "0123456789ABCDEFabcdef" }) return null
        val apdu = hex.hexToBytes()
        val bytes = apdu.map { it.toInt() and 255 }
        if (bytes[0] != 0x90 || bytes[2] != 0 || bytes[3] != 0) return null
        if (bytes.size > 5) {
            if (bytes.size != 6 + bytes[4] || bytes[4] == 0 || bytes.last() != 0) return null
        } else if (bytes[4] != 0) {
            return null
        }
        if (bytes[1] == 0xAF) return if (afterAdditionalFrame) apdu else null
        return if (bytes[1] in READ_INSTRUCTIONS) apdu else null
    }

    data class Outcome(val card: MadridTtpCard, val rounds: Int, val commands: Int)

    /** Relays the service's commands until it returns the card. A command outside the read set
     *  ends the exchange before it reaches the card. */
    fun read(post: (String, ByteArray) -> ByteArray, transceive: (ByteArray) -> ByteArray, log: (String) -> Unit = {}): Outcome {
        val greeting = parseObject(post(INIT_PATH, initBody()))
        if (statusCode(greeting) != "0000") {
            log("Session: status ${statusCode(greeting) ?: "missing"}")
            throw MadridTtpException.Service(statusCode(greeting) ?: "")
        }
        var response = parseObject(post(READING_PATH, readingBody(null)))
        var relayed = 0
        // Authentication continues across rounds: its 91AF reply is answered in the next one.
        var additionalFrame = false
        for (round in 1..MAX_ROUNDS) {
            val code = statusCode(response) ?: ""
            if (code == "0000" || code == "0001") {
                val card = parse(response) ?: run {
                    log("Round $round: status $code without card data")
                    throw MadridTtpException.InvalidResponse()
                }
                log("Finished after ${round - 1} rounds and $relayed card commands, status $code")
                return Outcome(card, round - 1, relayed)
            }
            if (code != "0010") {
                log("Round $round: service status ${code.ifEmpty { "missing" }}")
                throw MadridTtpException.Service(code)
            }
            val commands = (response["capdu"] as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            if (commands.isNullOrEmpty() || commands.size > MAX_COMMANDS_PER_ROUND || commands.any { it == null }) {
                log("Round $round: command list missing or too long")
                throw MadridTtpException.InvalidResponse()
            }
            val replies = mutableListOf<String>()
            for (hex in commands.filterNotNull()) {
                val apdu = permittedCommand(hex, additionalFrame) ?: run {
                    val instruction = hex.drop(2).take(2).toIntOrNull(16) ?: 0
                    log("Round $round: refused instruction %02X; nothing more was sent to the card".format(instruction))
                    throw MadridTtpException.RefusedCommand(instruction)
                }
                val reply = transceive(apdu)
                if (reply.size < 2) throw MadridTtpException.InvalidResponse()
                additionalFrame = reply[reply.size - 2] == 0x91.toByte() && reply[reply.size - 1] == 0xAF.toByte()
                replies.add(reply.hexString().uppercase())
                relayed++
            }
            log("Round $round: relayed ${commands.size} commands")
            response = parseObject(post(READING_PATH, readingBody(replies)))
        }
        log("Round budget exceeded")
        throw MadridTtpException.BudgetExceeded()
    }

    fun parseObject(data: ByteArray): JsonObject {
        if (data.isEmpty() || data.size > MAX_BODY) throw MadridTtpException.InvalidResponse()
        return runCatching { json.parseToJsonElement(data.toString(Charsets.UTF_8)) as? JsonObject }.getOrNull()
            ?: throw MadridTtpException.InvalidResponse()
    }

    fun statusCode(response: JsonObject): String? = text((response["status"] as? JsonObject)?.get("code"))

    /** `chargeState` "CADUCADO" marks a ticket that can no longer be used. */
    fun isExpired(ticket: JsonObject): Boolean = text(ticket["chargeState"])?.uppercase() == "CADUCADO"

    /** A Tarjeta MULTI has no `cardNumber`; its printed number is the order code and order number, as in MB0-12345678. */
    fun printedNumber(balance: JsonObject): String? {
        val code = text(balance["orderCode"]) ?: return null
        val number = text(balance["cardOrderNumber"]) ?: return null
        if (code.length > 8 || !code.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' }) return null
        if (number.length > 20 || !number.all { it in '0'..'9' }) return null
        return "$code-$number"
    }

    fun parse(response: JsonObject): MadridTtpCard? {
        val balance = response["balance"] as? JsonObject ?: return null
        val titles = response["titleList"] as? JsonObject
        val tickets = mutableListOf<MadridTtpCard.Ticket>()
        (balance["titTemp"] as? JsonObject)?.let { pass ->
            val name = text(pass["name"]) ?: return@let
            tickets.add(MadridTtpCard.Ticket(
                MadridTtpCard.Kind.PASS, name, zones = text(pass["validityZones"]), soldAt = date(pass["purchaseChargeDate"]),
                validFrom = date(pass["firstDateValCharge"]) ?: date(pass["initChargeDate"]),
                validUntil = date(pass["finalDateValCharge"]) ?: date(pass["finishChargeDate"]),
                lastUse = date(pass["lastValidationDate"]), expired = isExpired(pass),
            ))
        }
        for (key in listOf("titMV1", "titMV2", "titMV3")) {
            val ticket = balance[key] as? JsonObject ?: continue
            val name = text(ticket["name"]) ?: continue
            tickets.add(MadridTtpCard.Ticket(
                MadridTtpCard.Kind.MULTI_TRIP, name, zones = text(ticket["validityZones"]), soldAt = date(ticket["purchaseChargeDate"]),
                trips = text(ticket["trips"]), lastUse = date(ticket["lastValidationDate"]), expired = isExpired(ticket),
            ))
        }
        val summary = buildJsonObject {
            put("balance", balance)
            titles?.get("cardName")?.let { put("cardName", it) }
        }
        return MadridTtpCard(
            statusCode = statusCode(response) ?: "",
            cardNumber = text(balance["cardNumber"]) ?: printedNumber(balance),
            serial = text(balance["desfireSerial"]),
            cardName = text(titles?.get("cardName")),
            group = text(balance["groupName"]),
            profiles = (balance["profiles"] as? JsonArray).orEmpty().mapNotNull { element ->
                val profile = element as? JsonObject ?: return@mapNotNull null
                text(profile["profileName"])?.let { MadridTtpCard.Profile(it, date(profile["finishProfileDate"])) }
            },
            issueDate = date(balance["initAppDate"]),
            expiryDate = date(balance["finishAppDate"]),
            blocked = (balance["blockedApp"] as? JsonPrimitive)?.booleanOrNull ?: false,
            tickets = tickets,
            summaryJson = summary.toString(),
        )
    }

    fun text(value: JsonElement?): String? {
        val primitive = value as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        if (!primitive.isString && primitive.booleanOrNull != null) return null
        return primitive.content.trim().takeIf { it.isNotEmpty() && it.length <= 120 }
    }

    private val localDate = Regex("""^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?)?$""")
    private val madrid = ZoneId.of("Europe/Madrid")
    private val shown = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    /** Dates as the service wrote them in Madrid time. A time of midnight is left out; values
     *  with an explicit offset are shown in Madrid time; anything unrecognised stays verbatim. */
    fun date(value: JsonElement?): String? = text(value)?.let(::date)

    fun date(string: String): String {
        localDate.matchEntire(string)?.let { match ->
            val time = match.groupValues[2]
            return if (time.isEmpty() || time == "00:00") match.groupValues[1] else "${match.groupValues[1]} $time"
        }
        val normalized = string.replace(Regex("""([+-]\d{2})(\d{2})$"""), "$1:$2")
        val instant = runCatching { OffsetDateTime.parse(normalized).toInstant() }.getOrNull() ?: return string
        val text = LocalDateTime.ofInstant(instant, madrid).format(shown)
        return if (text.endsWith(" 00:00")) text.take(10) else text
    }
}
