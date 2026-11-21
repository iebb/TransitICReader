package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import java.io.File
import kotlinx.datetime.Instant
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Shares tests/runtime/fixtures/madrid-ttp.json with the Swift runtime test. Invented exchanges only. */
class MadridTtpProtocolTest {
    private val fixture = run {
        val root = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .first { File(it, "tests/runtime/fixtures/madrid-ttp.json").isFile }
        Json.parseToJsonElement(File(root, "tests/runtime/fixtures/madrid-ttp.json").readText()).jsonObject
    }
    private val session = fixture["session"]!!
    private val rounds = fixture["rounds"]!!.jsonArray.map { it.jsonObject }
    private val final = fixture["final"]!!.jsonObject
    private val firstResponse = rounds[0]["response"]!!.jsonObject

    private class Script(responses: List<JsonElement>, replies: List<String>) {
        val responses = ArrayDeque(responses.map { it.toString().toByteArray() })
        val replies = ArrayDeque(replies.map { it.hexToBytes() })
        val paths = mutableListOf<String>()
        val bodies = mutableListOf<JsonObject>()
        val commands = mutableListOf<String>()
        fun post(path: String, body: ByteArray): ByteArray {
            paths.add(path)
            bodies.add(Json.parseToJsonElement(body.toString(Charsets.UTF_8)).jsonObject)
            return responses.removeFirst()
        }
        fun transceive(apdu: ByteArray): ByteArray {
            commands.add(apdu.hexString())
            return replies.removeFirst()
        }
        fun read() = MadridTtpProtocol.read(::post, ::transceive)
    }

    private fun strings(element: JsonElement?) = element!!.jsonArray.map { it.jsonPrimitive.content }

    @Test fun commandGuardMatchesSwift() {
        strings(fixture["permittedCommands"]).forEach { assertNotNull(it, MadridTtpProtocol.permittedCommand(it, false)) }
        strings(fixture["refusedCommands"]).forEach { assertNull(it, MadridTtpProtocol.permittedCommand(it, false)) }
        assertNotNull(MadridTtpProtocol.permittedCommand("90AF000000", true))
        assertNull(MadridTtpProtocol.permittedCommand("90AF0000", true))
    }

    @Test fun relaysEveryRoundAndBuildsTheSameFieldsAsSwift() {
        val replies = rounds.flatMap { strings(it["replies"]) }
        val script = Script(listOf(session) + rounds.map { it["response"]!! } + final, replies)
        val outcome = script.read()
        assertEquals(listOf(MadridTtpProtocol.INIT_PATH) + List(3) { MadridTtpProtocol.READING_PATH }, script.paths)
        assertNull(script.bodies[1]["rapdu"])
        rounds.forEachIndexed { index, round ->
            assertEquals(strings(round["replies"]), strings(script.bodies[index + 2]["rapdu"]))
        }
        assertTrue(script.bodies.drop(1).all { it["updateCard"]!!.jsonPrimitive.boolean == false })
        assertEquals(rounds.flatMap { strings(it["response"]!!.jsonObject["capdu"]) }, script.commands)
        assertEquals(2, outcome.rounds)
        assertEquals(7, outcome.commands)
        val expected = fixture["expectedFields"]!!.jsonArray.map { it.jsonArray[0].jsonPrimitive.content to it.jsonArray[1].jsonPrimitive.content }
        assertEquals(expected, outcome.card.fields)
        assertNull(outcome.card.remainingTrips)
        assertFalse(outcome.card.summaryJson.contains("families"))

        val snapshot = MadridTtpDecoder.snapshot(outcome, "08A1B2C3".hexToBytes(), Instant.parse("2026-11-21T00:00:00Z"))
        assertEquals("04112233445566", snapshot.rawIdentifierValue)
        assertEquals("0010000000000000099", snapshot.realSerialNumber)
        assertNull(snapshot.balanceText)
    }

    @Test fun tripCountIsShownOnlyForOneTicket() {
        val balance = final["balance"]!!.jsonObject.toMutableMap()
        balance["titTemp"] = JsonNull
        balance["blockedApp"] = JsonPrimitive(true)
        val card = MadridTtpProtocol.parse(JsonObject(final + ("balance" to JsonObject(balance))))!!
        assertEquals(7, card.remainingTrips)
        assertTrue(card.fields.contains("Remaining Trips" to "7") && card.fields.contains("Status" to "Blocked"))
        balance["titMV2"] = balance["titMV1"]!!
        val twice = MadridTtpProtocol.parse(JsonObject(final + ("balance" to JsonObject(balance))))!!
        assertNull(twice.remainingTrips)
        assertTrue(twice.fields.contains("10 viajes (2) Remaining Trips" to "7"))
    }

    @Test fun expiredTicketsGiveNoTripCount() {
        val balance = final["balance"]!!.jsonObject.toMutableMap()
        val trips = balance["titMV1"]!!.jsonObject
        balance["titTemp"] = JsonNull
        balance["titMV1"] = JsonObject(trips + ("chargeState" to JsonPrimitive("CADUCADO")))
        val expired = MadridTtpProtocol.parse(JsonObject(final + ("balance" to JsonObject(balance))))!!
        assertNull(expired.remainingTrips)
        assertTrue(expired.fields.contains("10 viajes Status" to "Expired"))
        balance["titMV1"] = trips
        balance["titTemp"] = JsonObject(final["balance"]!!.jsonObject["titTemp"]!!.jsonObject + ("chargeState" to JsonPrimitive("CADUCADO")))
        assertEquals(7, MadridTtpProtocol.parse(JsonObject(final + ("balance" to JsonObject(balance))))!!.remainingTrips)
    }

    @Test fun datesAndTextMatchSwift() {
        val multi = final["balance"]!!.jsonObject.toMutableMap()
        multi["cardNumber"] = JsonNull
        multi["orderCode"] = JsonPrimitive("MB0")
        multi["cardOrderNumber"] = JsonPrimitive("00000042")
        val card = MadridTtpProtocol.parse(JsonObject(final + ("balance" to JsonObject(multi))))!!
        assertEquals("Card Number" to "MB0-00000042", card.fields.first())
        multi["cardOrderNumber"] = JsonPrimitive("0000 0042")
        assertNull(MadridTtpProtocol.parse(JsonObject(final + ("balance" to JsonObject(multi))))!!.cardNumber)

        assertEquals("2026-11-02", MadridTtpProtocol.date("2026-11-02 00:00:00"))
        assertEquals("2026-11-03 00:30", MadridTtpProtocol.date("2026-11-02T23:30:00Z"))
        assertEquals("31/12/2026", MadridTtpProtocol.date("31/12/2026"))
        assertNull(MadridTtpProtocol.date(JsonNull))
        assertNull(MadridTtpProtocol.text(JsonPrimitive(true)))
        assertEquals("7", MadridTtpProtocol.text(JsonPrimitive(7)))
    }

    @Test fun refusesWritesAndBoundsTheExchange() {
        val write = JsonObject(firstResponse + ("capdu" to JsonArray(listOf("9060000000", "903D00000801000000010000AA00", "9060000000").map(::JsonPrimitive))))
        val refused = Script(listOf(session, write), listOf("0401010100180591AF"))
        val error = assertThrows(MadridTtpException.RefusedCommand::class.java) { refused.read() }
        assertEquals(0x3D, error.instruction)
        assertEquals(listOf("9060000000"), refused.commands)
        assertEquals(2, refused.paths.size)

        val invalidSession = buildJsonObject { putJsonObject("status") { put("code", "MDD-001") } }
        assertEquals("MDD-001", assertThrows(MadridTtpException.Service::class.java) { Script(listOf(session, invalidSession), emptyList()).read() }.code)
        assertThrows(MadridTtpException.Service::class.java) { Script(listOf(invalidSession), emptyList()).read() }
        val noCard = buildJsonObject { putJsonObject("status") { put("code", "0000") }; put("balance", JsonNull) }
        assertThrows(MadridTtpException.InvalidResponse::class.java) { Script(listOf(session, noCard), emptyList()).read() }
        val empty = JsonObject(firstResponse + ("capdu" to JsonArray(emptyList())))
        assertThrows(MadridTtpException.InvalidResponse::class.java) { Script(listOf(session, empty), emptyList()).read() }
        val endless = JsonObject(firstResponse + ("capdu" to JsonArray(listOf(JsonPrimitive("9060000000")))))
        val looping = Script(listOf(session) + List(17) { endless }, List(16) { "9100" })
        assertThrows(MadridTtpException.BudgetExceeded::class.java) { looping.read() }
        assertEquals(MadridTtpProtocol.MAX_ROUNDS, looping.commands.size)
        assertThrows(MadridTtpException.InvalidResponse::class.java) { MadridTtpProtocol.parseObject("<html>".toByteArray()) }
    }
}
