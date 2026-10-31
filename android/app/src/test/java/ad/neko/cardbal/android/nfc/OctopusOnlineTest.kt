package ad.neko.cardbal.android.nfc

import android.content.SharedPreferences
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger

class OctopusOnlineTest {
    private val fixture = Json.parseToJsonElement(javaClass.classLoader!!.getResourceAsStream("octopus-online.json")!!
        .bufferedReader().readText()).jsonObject
    private val frames get() = fixture.getValue("frames").jsonArray.map { it.jsonPrimitive.content.hexToBytes() }
    /** The same exchange with FeliCa V2 (AES) commands 0x40, 0x42, 0x44 and 0x46. */
    private val framesV2 get() = fixture.getValue("frames_v2").jsonArray.map { it.jsonPrimitive.content.hexToBytes() }
    private val result get() = fixture.getValue("result").toString().toByteArray()

    @Test fun wireConventionsMalformedFramesAndVmBudgets() {
        assertEquals(fixture.getValue("device_info").jsonPrimitive.content, OctopusOcap.deviceInfo().hexString().lowercase())
        assertEquals(fixture.getValue("reply_abc").jsonPrimitive.content, OctopusOcap.reply("abc".toByteArray()).hexString().lowercase())
        assertEquals(0x97cc, OctopusOcap.checksum("123456".hexToBytes()))
        val frame = frames.first()
        for (end in frame.indices) assertThrows(OctopusProtocolException::class.java) { OctopusOcap.parse(frame.copyOf(end)) }
        val corrupt = frame.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        assertThrows(OctopusProtocolException::class.java) { OctopusOcap.parse(corrupt) }
        assertEquals(2, OctopusOcap.parse(frame + frame).size)
        val vm = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000) { error("Unexpected card command") }
        val invalid = OctopusOcap.Message(2, listOf(OctopusOcap.Instruction(1, 0, 3, listOf(16, 0))), emptyMap())
        assertThrows(OctopusProtocolException::class.java) { vm.run(invalid) }
        val loop = OctopusOcap.Message(2, listOf(OctopusOcap.Instruction(1, 0, 0x12, listOf(0, 0, 0))), emptyMap())
        assertThrows(OctopusProtocolException::class.java) { vm.run(loop) }
        val update = OctopusOcap.parse(frames[6]).single()
        val readOnly = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000) { error("Card update reached the card") }
        readOnly.run(update)
        assertEquals(1, readOnly.skippedCardUpdates)
        assertTrue(readOnly.cardOpcodes.isEmpty())
        val consented = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000, allowsCardUpdates = true) {
            byteArrayOf(2, (it[0] + 1).toByte())
        }
        consented.run(update)
        assertEquals(0, consented.skippedCardUpdates)
        assertEquals(setOf(0x16), consented.cardOpcodes)
        val reader = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000) { byteArrayOf(2, (it[0] + 1).toByte()) }
        reader.run(OctopusOcap.parse(frames[5]).single())
        assertEquals(0, reader.skippedCardUpdates)
        assertEquals(setOf(0x14), reader.cardOpcodes)
    }

    @Test fun v2CommandsReadWithoutConsentAndWriteV2IsSkipped() {
        assertEquals(setOf(0x02, 0x04, 0x06, 0x0A, 0x0C, 0x0E, 0x10, 0x12, 0x14, 0x1A, 0x1E, 0x22, 0x24, 0x28,
            0x2E, 0x32, 0x34, 0x38, 0x3A, 0x3C, 0x40, 0x42, 0x44), OctopusEnquiryVm.READ_ONLY_CARD_OPCODES)
        for (opcode in listOf(0x08, 0x16, 0x3E, 0x46, 0x4C)) assertFalse(opcode in OctopusEnquiryVm.READ_ONLY_CARD_OPCODES)
        assertEquals(10_000, OctopusEnquiryClient.REQUEST_TIMEOUT_MILLIS)
        val reader = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000) { byteArrayOf(2, (it[0] + 1).toByte()) }
        for (index in 3..5) reader.run(OctopusOcap.parse(framesV2[index]).single())
        assertEquals(0, reader.skippedCardUpdates)
        assertEquals(setOf(0x40, 0x42, 0x44), reader.cardOpcodes)
        val update = OctopusOcap.parse(framesV2[6]).single()
        val readOnly = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000) { error("Write V2 reached the card") }
        readOnly.run(update)
        assertEquals(1, readOnly.skippedCardUpdates)
        assertTrue(readOnly.cardOpcodes.isEmpty())
        val consented = OctopusEnquiryVm(emptyMap(), System.nanoTime() + 10_000_000_000, allowsCardUpdates = true) {
            byteArrayOf(2, (it[0] + 1).toByte())
        }
        consented.run(update)
        assertEquals(0, consented.skippedCardUpdates)
        assertEquals(setOf(0x46), consented.cardOpcodes)
    }

    @Test fun onlyAuthenticatedCorroboratedResultsCalibrateBothOffsets() {
        val ops = setOf(0x10, 0x12, 0x14)
        val confirmed = OctopusCardMetadata.calibrated(result, 900, ops)!!
        assertEquals(350, confirmed.offset)
        assertEquals("123456789", confirmed.cardNumber)
        assertEquals("R30", confirmed.serviceStatus)
        assertEquals(500, OctopusCardMetadata.calibrated(result, 1050, ops)!!.offset)
        assertNull(OctopusCardMetadata.calibrated(result, 901, ops))
        assertNull(OctopusCardMetadata.calibrated(result, 900, emptySet()))
        // Each step of the authenticated read may come from either command generation.
        for (accepted in listOf(setOf(0x40, 0x42, 0x44), setOf(0x10, 0x42, 0x14), setOf(0x40, 0x12, 0x44, 0x46))) {
            assertEquals(confirmed, OctopusCardMetadata.calibrated(result, 900, accepted))
        }
        for (rejected in listOf(setOf(0x40, 0x42), setOf(0x10, 0x12, 0x06), setOf(0x42, 0x44, 0x46))) {
            assertNull(OctopusCardMetadata.calibrated(result, 900, rejected))
        }
        assertNull(OctopusCardMetadata.calibrated("""{"cardDataVO":{"balance":0,"status":"R30"}}""".toByteArray(), 350, ops))
        assertNull(OctopusCardMetadata.calibrated("""{"cardDataVO":{"balance":54.99,"octopusNo":"123456789","status":"R30"}}""".toByteArray(), 900, ops))
        assertEquals(350, OctopusCardMetadata.calibrated("""{"cardDataVO":{"balance":-25,"octopusNo":"123456789","status":"R30"}}""".toByteArray(), 100, ops)!!.offset)
        assertNull(OctopusCardMetadata.calibrated("""{"cardDataVO":{"balance":55,"octopusNo":"123456789","octopusNoLong":987654321,"status":"R30"}}""".toByteArray(), 900, ops))
    }

    @Test fun metadataSurvivesStoreRecreationAndUsesNormalizedIdm() {
        val values = mutableMapOf<String, Any>()
        val preferences = preferences(values)
        val store = OctopusMetadataStore(preferences)
        assertTrue(store.onlineEnabled)
        values[OctopusMetadataStore.ENABLED_KEY] = false
        assertFalse(store.onlineEnabled)
        assertFalse(store.cardUpdatesAllowed)
        values[OctopusMetadataStore.CARD_UPDATES_KEY] = true
        assertTrue(store.cardUpdatesAllowed)
        val metadata = OctopusCardMetadata("123456789", 350, "R30")
        store.save("010203040506abcd", metadata)
        assertEquals(metadata, OctopusMetadataStore(preferences).metadata("010203040506ABCD"))
        assertNull(store.metadata("010203040506ABCE"))
        store.save("010203040506ABCD", metadata.copy(offset = 0))
        assertEquals(metadata, store.metadata("010203040506abcd"))
    }

    @Test fun realHttpRoundTripPreservesOpaqueReadsWritesAndRejectsFailures() {
        val index = AtomicInteger()
        val redirects = AtomicInteger()
        val server = LocalServer { path, body, headers ->
            assertEquals("application/ocap", headers["content-type"])
            when {
                path.startsWith("/redirect/") -> Reply(302, headers = "Location: /must-not-follow\r\n")
                path.startsWith("/must-not-follow") -> { redirects.incrementAndGet(); Reply(500) }
                path.startsWith("/error/") -> Reply(503)
                path.startsWith("/slow/") -> { Thread.sleep(200); Reply(503) }
                path.endsWith("/index.htm") -> {
                    assertEquals(0, body.size)
                    val greeting = ("JSESSIONID=" + if (path.startsWith("/bad-session/")) "bad/path" else "invented-session").toByteArray()
                    Reply(200, greeting)
                }
                path == "/success/service.htm;jsessionid=invented-session" -> {
                    val round = index.getAndIncrement()
                    if (round == 0) assertArrayEquals(OctopusOcap.deviceInfo(), body)
                    else assertEquals("RPLY", body.copyOfRange(9, 13).toString(Charsets.US_ASCII))
                    val response = frames[round]
                    Reply(200, response)
                }
                path == "/success-v2/service.htm;jsessionid=invented-session" -> {
                    val round = index.getAndIncrement()
                    if (round == 0) assertArrayEquals(OctopusOcap.deviceInfo(), body)
                    Reply(200, framesV2[round])
                }
                else -> Reply(501)
            }
        }
        try {
            val base = "http://127.0.0.1:${server.port}"
            val readOnly = OctopusEnquiryClient("$base/success", allowLoopback = true)
            val (data, opcodes) = readOnly.enquire { command ->
                assertNotEquals(0x16, command[0].toInt())
                byteArrayOf(3, (command[0] + 1).toByte(), 0)
            }
            assertEquals(fixture.getValue("result"), Json.parseToJsonElement(data.toString(Charsets.UTF_8)))
            assertEquals(frames.size, index.get())
            assertEquals(setOf(0, 2, 0x10, 0x12, 0x14), opcodes)
            assertEquals(1, readOnly.skippedCardUpdates)
            index.set(0)
            val updating = OctopusEnquiryClient("$base/success", allowLoopback = true)
            val (_, updateOpcodes) = updating.enquire(allowsCardUpdates = true) { command ->
                byteArrayOf(3, (command[0] + 1).toByte(), 0)
            }
            assertEquals(frames.size, index.get())
            assertEquals(setOf(0, 2, 0x10, 0x12, 0x14, 0x16), updateOpcodes)
            assertEquals(0, updating.skippedCardUpdates)
            // A V2 (AES) exchange with card updates off reads and calibrates; Write V2 never reaches the card.
            index.set(0)
            val v2 = OctopusEnquiryClient("$base/success-v2", allowLoopback = true)
            val (v2Data, v2Opcodes) = v2.enquire { command ->
                assertNotEquals(0x46, command[0].toInt())
                byteArrayOf(3, (command[0] + 1).toByte(), 0)
            }
            assertEquals(framesV2.size, index.get())
            assertEquals(setOf(0, 2, 0x40, 0x42, 0x44), v2Opcodes)
            assertEquals(1, v2.skippedCardUpdates)
            assertEquals(350, OctopusCardMetadata.calibrated(v2Data, 900, v2Opcodes)!!.offset)
            for (mode in listOf("error", "redirect", "bad-session", "slow")) {
                assertThrows(java.io.IOException::class.java) {
                    OctopusEnquiryClient("$base/$mode", allowLoopback = true, timeoutMillis = 50).enquire { error("Failure contacted card") }
                }
            }
            assertEquals(0, redirects.get())
            assertThrows(OctopusProtocolException::class.java) {
                OctopusEnquiryClient("$base/success").enquire { error("HTTP must require loopback override") }
            }
        } finally { server.close() }
    }

    @Test fun rawFelicaRelayKeepsLengthAndChecksPollingIdentity() {
        val idm = "0102030405060708".hexToBytes()
        val pmm = ByteArray(8)
        val protocol = FeliCaProtocol(idm) { request ->
            if (request[1] == 0.toByte()) byteArrayOf(20, 1) + idm + pmm + byteArrayOf(0x80.toByte(), 8)
            else byteArrayOf(3, (request[1] + 1).toByte(), 0)
        }
        assertTrue(protocol.polling("8008"))
        assertArrayEquals(byteArrayOf(3, 0x17, 0), protocol.exchangeOnline(byteArrayOf(0x16, 1, 2)))
        assertThrows(OctopusProtocolException::class.java) { protocol.exchangeOnline(byteArrayOf()) }
    }

    private fun preferences(values: MutableMap<String, Any>): SharedPreferences {
        val editor = Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
            when (method.name) {
                "putString", "putInt", "putBoolean" -> { values[args[0] as String] = args[1]; proxy }
                "apply" -> null
                "commit" -> true
                else -> error(method.name)
            }
        } as SharedPreferences.Editor
        return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getString", "getInt", "getBoolean" -> values[args[0] as String] ?: args[1]
                "edit" -> editor
                else -> error(method.name)
            }
        } as SharedPreferences
    }

    private data class Reply(val status: Int, val body: ByteArray = byteArrayOf(), val headers: String = "")

    /** JDK-only HTTP stand-in; the Android test compiler excludes jdk.httpserver. */
    private class LocalServer(private val handle: (String, ByteArray, Map<String, String>) -> Reply) : AutoCloseable {
        private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port get() = socket.localPort
        @Volatile private var failure: Throwable? = null
        private val thread = Thread {
            while (!socket.isClosed) {
                try {
                    socket.accept().use { client ->
                        client.soTimeout = 1000
                        val input = client.getInputStream()
                        val headerBytes = ByteArrayOutputStream()
                        while (true) {
                            val byte = input.read()
                            if (byte < 0) error("Truncated HTTP request")
                            headerBytes.write(byte)
                            if (headerBytes.size() > 16384) error("Oversized HTTP headers")
                            if (headerBytes.toString("US-ASCII").endsWith("\r\n\r\n")) break
                        }
                        val lines = headerBytes.toString("US-ASCII").split("\r\n")
                        assertTrue(lines[0].startsWith("POST "))
                        val headers = lines.drop(1).filter { ':' in it }.associate {
                            it.substringBefore(':').lowercase() to it.substringAfter(':').trim()
                        }
                        val body = ByteArray(headers["content-length"]!!.toInt())
                        var position = 0
                        while (position < body.size) {
                            val count = input.read(body, position, body.size - position)
                            if (count < 0) error("Truncated HTTP body")
                            position += count
                        }
                        val reply = handle(lines[0].split(' ')[1], body, headers)
                        val responseHeaders = "HTTP/1.1 ${reply.status} Test\r\nContent-Length: ${reply.body.size}\r\nConnection: close\r\n${reply.headers}\r\n"
                        // A timed-out caller may close before the injected delay ends.
                        try {
                            client.getOutputStream().write(responseHeaders.toByteArray() + reply.body)
                        } catch (_: java.net.SocketException) {}
                    }
                } catch (error: Throwable) {
                    if (!socket.isClosed) failure = error
                }
            }
        }.apply { isDaemon = true; start() }

        override fun close() {
            socket.close()
            thread.join(2000)
            failure?.let { throw AssertionError("HTTP stand-in failed", it) }
        }
    }
}
