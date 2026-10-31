package ad.neko.cardbal.android.data

import android.content.SharedPreferences
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.lang.reflect.Proxy
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class KoreanTripCrowdsourcingTest {
    private val cardID = "1010010000001234"
    private val history = listOf("  0102030405060708090a0b0c0d0e0f10  ", "aabbccddeeffaabb", "0102030405060708090A", "ZZ")

    private fun snapshot(
        family: String = "T-money", technology: String = "ISO7816", serial: String? = cardID,
        identifier: String = "1010 0100", transit: List<String> = history,
    ) = TransitCardSnapshot(
        technology = technology, cardFamily = family, identifierLabel = "UID", identifierValue = identifier,
        rawIdentifierValue = identifier.replace(" ", ""), realSerialNumber = serial, rawTransitHistory = transit,
        rawTransactions = listOf("00112233"),
    )

    @Test fun recordsMatchTheIphoneVectors() {
        val records = KoreanTripCrowdsourcing.makeRecords(snapshot())
        // Hex that holds no bytes is skipped.
        assertEquals(3, records.size)
        val cardHash = "6abeaeaa60f2a1df87043c2761a3aae2b915577f32feb7fba1abc123b727a156"
        assertEquals(KoreanTripCrowdsourcingRecord(
            dedupHash = "d418d9aa8615d3c15e753161814cb3084a8c5ab3741adcd0628f468ffa79eb16", hashedCardID = cardHash,
            cardIDLast4 = "1234", bytes0508 = "06070809", bytes090A = "0A0B", allBytes = "0102030405060708090A0B0C0D0E0F10",
            cardFamily = "T-money"), records[0])
        // Fewer than 9 bytes: neither slice.
        assertEquals(KoreanTripCrowdsourcingRecord(
            dedupHash = "9be8757cc3917b17cf74c7cd8fae149317b06253fb0341dc5328cc4691ced473", hashedCardID = cardHash,
            cardIDLast4 = "1234", bytes0508 = "", bytes090A = "", allBytes = "AABBCCDDEEFFAABB", cardFamily = "T-money"), records[1])
        // 10 bytes: bytes 0x05-0x08 but not 0x09-0x0A.
        assertEquals(KoreanTripCrowdsourcingRecord(
            dedupHash = "c7f1f8f45f94c6164357640a447a0ff1ac698c0d9bac00fe2114a775a47a7afc", hashedCardID = cardHash,
            cardIDLast4 = "1234", bytes0508 = "06070809", bytes090A = "", allBytes = "0102030405060708090A", cardFamily = "T-money"), records[2])
        // Exactly 9 and 11 bytes are enough for each slice.
        val edges = KoreanTripCrowdsourcing.makeRecords(snapshot(transit = listOf("000000000011223344", "0000000000112233445566")))
        assertEquals(listOf("11223344" to "", "11223344" to "5566"), edges.map { it.bytes0508 to it.bytes090A })
        // Card IDs are uppercased and keep letters and digits only; without a serial the shown identifier is used.
        assertEquals("ABC123", KoreanTripCrowdsourcing.stableCardID(snapshot(serial = " abc-12 3 ")))
        assertEquals("10100100", KoreanTripCrowdsourcing.stableCardID(snapshot(serial = "")))
        assertEquals("10100100", KoreanTripCrowdsourcing.stableCardID(snapshot(serial = null)))
        val short = KoreanTripCrowdsourcing.makeRecords(snapshot(serial = "abc-123", transit = listOf("01")))
        assertEquals("e0bebd22819993425814866b62701e2919ea26f1370499c1037b53b9d49c2c8a", short.single().hashedCardID)
        assertEquals("C123", short.single().cardIDLast4)
        assertEquals(KoreanTripCrowdsourcing.sha256Hex("ABC12301"), short.single().dedupHash)
        // The iPhone's hex reader skips non-hex characters and pads an odd count.
        assertEquals("0ABC", KoreanTripCrowdsourcing.hexData("a:bc").joinToString("") { "%02X".format(it) })
    }

    @Test fun onlyKoreanTripCardsWithHistoryAndAnIdAreEligible() {
        assertTrue(KoreanTripCrowdsourcing.isEligible(snapshot()))
        assertTrue(KoreanTripCrowdsourcing.isEligible(snapshot(family = "EZL / Cashbee")))
        for (family in listOf("T-money", "tmoney", "T-money (Seoul)", "EZL", "ezl / cashbee", "Cashbee", " Cashbee ")) {
            assertTrue(family, KoreanTripCrowdsourcing.isKoreanTripBrand(family))
        }
        for (family in listOf("EZ-Link", "EZLink", "CEPAS", "U-Money", "Railplus", "K-Cash", "Octopus", "tmoney card")) {
            assertFalse(family, KoreanTripCrowdsourcing.isKoreanTripBrand(family))
        }
        assertFalse(KoreanTripCrowdsourcing.isEligible(snapshot(technology = "FeliCa")))
        assertFalse(KoreanTripCrowdsourcing.isEligible(snapshot(family = "EZ-Link")))
        assertFalse(KoreanTripCrowdsourcing.isEligible(snapshot(transit = emptyList())))
        assertFalse(KoreanTripCrowdsourcing.isEligible(snapshot(serial = "--", identifier = " ")))
        assertTrue(KoreanTripCrowdsourcing.makeRecords(snapshot(serial = "--", identifier = " ")).isEmpty())
    }

    @Test fun loopbackUploadSendsOnlyNewRecordsAndRemembersThemAfterSuccess() {
        val values = mutableMapOf<String, Any>()
        val status = AtomicInteger(200)
        val server = LocalServer { Reply(status.get(), """{"accepted":3,"duplicates":0}""".toByteArray()) }
        try {
            val endpoint = "http://127.0.0.1:${server.port}/ingest/korean-trip-records"
            val uploader = KoreanTripCrowdsourcingUploader(preferences(values), endpoint, "9.8.7", allowLoopback = true, timeoutMillis = 2000)
            assertEquals(3, uploader.upload(snapshot()))
            val request = server.requests.single()
            assertEquals("POST /ingest/korean-trip-records", request.line.substringBeforeLast(' '))
            assertEquals("application/json", request.headers["content-type"])
            val body = Json.parseToJsonElement(request.body.toString(Charsets.UTF_8)).jsonObject
            assertEquals(setOf("records", "source", "appVersion"), body.keys)
            assertEquals("cardbal-android", body.getValue("source").jsonPrimitive.content)
            assertEquals("9.8.7", body.getValue("appVersion").jsonPrimitive.content)
            val records = body.getValue("records").jsonArray.map { it.jsonObject }
            assertEquals(KoreanTripCrowdsourcing.makeRecords(snapshot()).map { it.dedupHash }, records.map { it.getValue("dedupHash").jsonPrimitive.content })
            for (record in records) {
                assertEquals(setOf("dedupHash", "hashedCardID", "cardIDLast4", "bytes0508", "bytes090A", "allBytes", "cardFamily"), record.keys)
            }
            assertEquals("06070809", records[0].getValue("bytes0508").jsonPrimitive.content)
            assertEquals(3, storedHashes(values).size)

            // The same scan again, from a fresh uploader reading the saved hashes, sends nothing.
            val restarted = KoreanTripCrowdsourcingUploader(preferences(values), endpoint, "9.8.7", allowLoopback = true, timeoutMillis = 2000)
            assertEquals(0, restarted.upload(snapshot()))
            assertEquals(0, uploader.upload(snapshot()))
            assertEquals(1, server.requests.size)

            // A failed upload sends the new record but does not remember it, so the next scan offers it again.
            val longer = snapshot(transit = history + "11223344556677889900AABB")
            status.set(500)
            assertEquals(0, restarted.upload(longer))
            assertEquals(2, server.requests.size)
            assertEquals(1, recordsOf(server.requests[1]).size)
            assertEquals(3, storedHashes(values).size)
            status.set(302)
            assertEquals(0, restarted.upload(longer))
            assertEquals(3, server.requests.size)
            status.set(204)
            assertEquals(1, restarted.upload(longer))
            assertEquals(1, recordsOf(server.requests[3]).size)
            assertEquals(4, storedHashes(values).size)
            assertEquals(0, restarted.upload(longer))
            assertEquals(4, server.requests.size)

            // Turned off in Settings, or an ineligible card: nothing is sent.
            values[KoreanTripCrowdsourcingPreferences.ENABLED_KEY] = false
            assertFalse(restarted.isEnabled)
            assertEquals(0, restarted.upload(snapshot(serial = "99")))
            values.remove(KoreanTripCrowdsourcingPreferences.ENABLED_KEY)
            assertTrue(restarted.isEnabled)
            assertEquals(0, restarted.upload(snapshot(serial = "99", family = "EZ-Link")))
            assertEquals(0, restarted.upload(snapshot(serial = "99", technology = "FeliCa")))
            assertEquals(4, server.requests.size)

            // Plain HTTP needs the test-only loopback override, and never reaches another host.
            val strict = KoreanTripCrowdsourcingUploader(preferences(mutableMapOf()), endpoint, "9.8.7", timeoutMillis = 2000)
            assertEquals(0, strict.upload(snapshot()))
            val elsewhere = KoreanTripCrowdsourcingUploader(preferences(mutableMapOf()), "http://192.0.2.1/ingest", "9.8.7", allowLoopback = true, timeoutMillis = 2000)
            assertEquals(0, elsewhere.upload(snapshot()))
            assertEquals(4, server.requests.size)
        } finally { server.close() }
        // Unreachable: the failure is swallowed and nothing is remembered.
        val closed = mutableMapOf<String, Any>()
        val offline = KoreanTripCrowdsourcingUploader(preferences(closed), "http://127.0.0.1:${server.port}/ingest", "9.8.7", allowLoopback = true, timeoutMillis = 500)
        assertEquals(0, offline.upload(snapshot()))
        assertNull(closed[KoreanTripCrowdsourcingPreferences.UPLOADED_HASHES_KEY])
    }

    @Test fun rememberedHashesAreCappedKeepingTheNewest() {
        val values = mutableMapOf<String, Any>(
            KoreanTripCrowdsourcingPreferences.UPLOADED_HASHES_KEY to Json.encodeToString(
                ListSerializer(String.serializer()),
                (0 until KoreanTripCrowdsourcingPreferences.MAX_UPLOADED_HASHES).map { "old$it" }),
        )
        val server = LocalServer { Reply(200) }
        try {
            val uploader = KoreanTripCrowdsourcingUploader(preferences(values), "http://127.0.0.1:${server.port}/ingest", "9.8.7",
                allowLoopback = true, timeoutMillis = 2000)
            assertEquals(3, uploader.upload(snapshot()))
            val stored = storedHashes(values)
            assertEquals(5000, KoreanTripCrowdsourcingPreferences.MAX_UPLOADED_HASHES)
            assertEquals(5000, stored.size)
            assertEquals(listOf("old3", "old4"), stored.take(2))
            assertEquals(KoreanTripCrowdsourcing.makeRecords(snapshot()).map { it.dedupHash }, stored.takeLast(3))
        } finally { server.close() }
    }

    @Test fun productionSettingsMatchTheIphone() {
        assertEquals("https://korean-trip-crowdsourcing.ieb.app/ingest/korean-trip-records", KoreanTripCrowdsourcingPreferences.ENDPOINT)
        assertEquals("cardbal-android", KoreanTripCrowdsourcingPreferences.SOURCE)
        assertEquals("koreanTripCrowdsourcingEnabled", KoreanTripCrowdsourcingPreferences.ENABLED_KEY)
        assertEquals("koreanTripCrowdsourcingUploadedHashes", KoreanTripCrowdsourcingPreferences.UPLOADED_HASHES_KEY)
        // On by default.
        assertTrue(KoreanTripCrowdsourcingUploader(preferences(mutableMapOf()), "https://127.0.0.1/never-contacted").isEnabled)
    }

    private fun recordsOf(request: Request) =
        Json.parseToJsonElement(request.body.toString(Charsets.UTF_8)).jsonObject.getValue("records").jsonArray.map { it as JsonObject }

    private fun storedHashes(values: Map<String, Any>): List<String> =
        Json.parseToJsonElement(values.getValue(KoreanTripCrowdsourcingPreferences.UPLOADED_HASHES_KEY) as String).jsonArray.map { it.jsonPrimitive.content }

    private fun preferences(values: MutableMap<String, Any>): SharedPreferences {
        val editor = Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
            when (method.name) {
                "putString", "putBoolean" -> { values[args[0] as String] = args[1]; proxy }
                "apply" -> null
                "commit" -> true
                else -> error(method.name)
            }
        } as SharedPreferences.Editor
        return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getString", "getBoolean" -> values[args[0] as String] ?: args[1]
                "edit" -> editor
                else -> error(method.name)
            }
        } as SharedPreferences
    }

    private class Request(val line: String, val headers: Map<String, String>, val body: ByteArray)
    private class Reply(val status: Int, val body: ByteArray = byteArrayOf())

    /** JDK-only HTTP stand-in on loopback; the real endpoint is never contacted. */
    private class LocalServer(private val handle: (Request) -> Reply) : AutoCloseable {
        private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port = socket.localPort
        val requests = CopyOnWriteArrayList<Request>()
        @Volatile private var failure: Throwable? = null
        private val thread = Thread {
            while (!socket.isClosed) {
                try {
                    socket.accept().use { client ->
                        client.soTimeout = 2000
                        val input = client.getInputStream()
                        val headerBytes = ByteArrayOutputStream()
                        while (!headerBytes.toString("US-ASCII").endsWith("\r\n\r\n")) {
                            val byte = input.read()
                            if (byte < 0) error("Truncated HTTP request")
                            headerBytes.write(byte)
                            if (headerBytes.size() > 16384) error("Oversized HTTP headers")
                        }
                        val lines = headerBytes.toString("US-ASCII").split("\r\n")
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
                        val request = Request(lines[0], headers, body)
                        val reply = handle(request)
                        requests += request
                        val extra = if (reply.status in 300..399) "Location: /must-not-follow\r\n" else ""
                        val head = "HTTP/1.1 ${reply.status} Test\r\nContent-Length: ${reply.body.size}\r\nConnection: close\r\n$extra\r\n"
                        client.getOutputStream().write(head.toByteArray() + reply.body)
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
