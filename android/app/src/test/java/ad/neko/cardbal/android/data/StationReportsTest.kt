package ad.neko.cardbal.android.data

import android.content.SharedPreferences
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.lang.reflect.Proxy
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList

class StationReportsTest {
    private val submissionId = "0f8fad5b-d9cb-469f-a165-70867728950e"
    private val deviceId = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    private val cardHash = StationReports.cardIdHash("FeliCa|0123456789ABCDEF")

    /** The server's `allowedFields` set; it rejects any other top-level key. */
    private val serverFields: Set<String> by lazy {
        val validation = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
            .map { File(it, "services/station-reports/src/validation.ts") }
            .first { it.isFile }
            .readText()
        val block = Regex("""allowedFields\s*=\s*new Set\(\[(.*?)]\)""", RegexOption.DOT_MATCHES_ALL).find(validation)!!.groupValues[1]
        Regex("\"([A-Za-z]+)\"").findAll(block).map { it.groupValues[1] }.toSet().also { assertTrue(it.size >= 16) }
    }

    private fun fullCorrection() = StationReportForm(
        kind = StationReportKind.Correction,
        stationName = "  Shinjuku ",
        stationCode = " 25-01 ",
        suggestedCode = "25-02",
        lines = "Yamanote",
        operatorName = "JR East",
        city = "Tokyo",
        country = "Japan",
        notes = "Gate shows a different code.\nSecond line.",
    )

    private fun payload(form: StationReportForm, location: StationReportLocationPayload? = null) = form.payload(
        submissionId = submissionId,
        location = location,
        cardFamily = "Suica",
        cardIdHash = cardHash,
        appVersion = "2.5.2",
        deviceId = deviceId,
    )

    private fun encoded(payload: StationReportPayload): JsonObject =
        Json.parseToJsonElement(StationReports.json.encodeToString(StationReportPayload.serializer(), payload)).jsonObject

    @Test fun payloadUsesOnlyServerFieldsAndOmitsEmptyOptionals() {
        val full = encoded(payload(fullCorrection(), StationReports.location(35.6896, 139.7006, 12.5)))
        assertEquals(serverFields, full.keys)
        assertEquals(setOf("latitude", "longitude", "accuracyMeters"), full.getValue("location").jsonObject.keys)
        assertEquals("android", full.getValue("source").jsonPrimitive.content)
        assertEquals("correction", full.getValue("reportType").jsonPrimitive.content)
        assertEquals("JR East", full.getValue("operator").jsonPrimitive.content)
        assertEquals("Shinjuku", full.getValue("stationName").jsonPrimitive.content)
        assertEquals("25-01", full.getValue("stationCode").jsonPrimitive.content)

        val pinned = encoded(payload(StationReportForm(stationName = "Shinjuku"), StationReports.location(35.0, 139.0)))
        assertEquals(setOf("latitude", "longitude"), pinned.getValue("location").jsonObject.keys)

        val minimal = encoded(payload(StationReportForm(stationName = "Shinjuku", lines = "   ", notes = "\n")))
        assertTrue(serverFields.containsAll(minimal.keys))
        assertEquals(
            setOf("submissionId", "reportType", "stationName", "cardFamily", "cardIdHash", "appVersion", "deviceId", "source"),
            minimal.keys,
        )
        assertEquals("missing", minimal.getValue("reportType").jsonPrimitive.content)
    }

    @Test fun trimsValuesAndSendsTheCorrectCodeOnlyForCorrections() {
        val correction = payload(fullCorrection())
        assertEquals("Shinjuku", correction.stationName)
        assertEquals("25-01", correction.stationCode)
        assertEquals("25-02", correction.suggestedCode)
        assertEquals("Gate shows a different code.\nSecond line.", correction.notes)
        assertEquals(StationReports.SOURCE, correction.source)

        val missing = payload(fullCorrection().copy(kind = StationReportKind.Missing))
        assertEquals("missing", missing.reportType)
        assertEquals("25-01", missing.stationCode)
        assertNull(missing.suggestedCode)
        assertNull(payload(StationReportForm(stationName = "A", stationCode = "  ")).stationCode)
    }

    @Test fun submitRulesMatchIos() {
        val valid = StationReportForm(stationName = "Shinjuku")
        assertTrue(valid.canSubmit(isSubmitting = false))
        assertFalse(valid.canSubmit(isSubmitting = true))
        assertEquals(StationReportKind.Missing, StationReportForm().kind)
        assertFalse(StationReportForm().canSubmit(false))
        assertFalse(StationReportForm(stationName = " \n ").canSubmit(false))
        assertTrue(valid.copy(stationName = "a".repeat(120)).canSubmit(false))
        assertFalse(valid.copy(stationName = "a".repeat(121)).canSubmit(false))
        // The untrimmed length counts, as on iOS.
        assertFalse(valid.copy(stationName = "a".repeat(120) + " ").canSubmit(false))

        val correction = valid.copy(kind = StationReportKind.Correction)
        assertFalse(correction.canSubmit(false))
        assertFalse(correction.copy(stationCode = "   ").canSubmit(false))
        assertTrue(correction.copy(stationCode = "A1").canSubmit(false))

        for ((form, limit) in listOf<Pair<(String) -> StationReportForm, Int>>(
            { v: String -> valid.copy(stationCode = v) } to 64,
            { v: String -> valid.copy(suggestedCode = v) } to 64,
            { v: String -> valid.copy(lines = v) } to 240,
            { v: String -> valid.copy(operatorName = v) } to 120,
            { v: String -> valid.copy(city = v) } to 120,
            { v: String -> valid.copy(country = v) } to 120,
            { v: String -> valid.copy(notes = v) } to 1200,
        )) {
            assertTrue(form("x".repeat(limit)).canSubmit(false))
            assertFalse(form("x".repeat(limit + 1)).canSubmit(false))
        }
    }

    @Test fun identityHashesTheSavedCardIdAndKeepsOneDeviceId() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", StationReports.cardIdHash("abc"))
        assertEquals("38b9a7dc1d32761fbe6bcc5bf54572113a60ae54d07a6037351883011c53f144", cardHash)
        assertEquals("f1631fcf6b9590405cecc1a4fd479b5ac69cec65b3d90adca8b86b4d25414e15", StationReports.cardIdHash("ISO7816|카드"))

        val values = mutableMapOf<String, Any>()
        val preferences = preferences(values)
        val first = StationReports.deviceId(preferences)
        assertTrue(first.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")))
        assertEquals(first, values[StationReports.DEVICE_ID_KEY])
        assertEquals("stationReportDeviceID", StationReports.DEVICE_ID_KEY)
        assertEquals(first, StationReports.deviceId(preferences))
        values[StationReports.DEVICE_ID_KEY] = "not-a-uuid"
        val replaced = StationReports.deviceId(preferences)
        assertNotEquals("not-a-uuid", replaced)
        assertEquals(replaced, values[StationReports.DEVICE_ID_KEY])

        val ids = (1..20).map { StationReports.newSubmissionId() }.toSet()
        assertEquals(20, ids.size)
        assertTrue(ids.all { it == it.lowercase() && it.length == 36 })
    }

    @Test fun prefillsOnlyASingleDistinctStationCode() {
        fun tx(entry: String?, exit: String?) = TransitTransaction(type = "Train", entryStationCode = entry, exitStationCode = exit)
        assertEquals("25-01", StationReports.prefilledStationCode(tx("25-01", " 25-01 ")))
        assertEquals("25-01", StationReports.prefilledStationCode(tx(" ", "25-01")))
        assertEquals("25-01", StationReports.prefilledStationCode(tx("25-01", null)))
        assertNull(StationReports.prefilledStationCode(tx("25-01", "25-02")))
        assertNull(StationReports.prefilledStationCode(tx(null, "")))
    }

    @Test fun locationStaysInsideServerRanges() {
        assertEquals(StationReportLocationPayload(35.5, -170.0, null), StationReports.location(35.5, 190.0))
        assertEquals(StationReportLocationPayload(90.0, 180.0 - 360.0, 25.0), StationReports.location(91.0, 180.0, 25.0))
        assertNull(StationReports.location(35.0, 139.0, -1.0)!!.accuracyMeters)
        assertNull(StationReports.location(35.0, 139.0, 100_001.0)!!.accuracyMeters)
        assertNull(StationReports.location(Double.NaN, 139.0))
    }

    @Test fun loopbackPostReturnsTheReferenceAndRejectsFailures() {
        val requests = CopyOnWriteArrayList<Request>()
        val server = LocalServer { request ->
            requests += request
            when (request.path) {
                "/created/api/v1/station-reports" -> Reply(201, """{"id":"$submissionId","status":"pending","duplicate":false}""")
                "/duplicate/api/v1/station-reports" -> Reply(200, """{"id":"$submissionId","status":"pending","duplicate":true}""")
                "/invalid/api/v1/station-reports" -> Reply(400, """{"error":"invalid_report","field":"stationName","message":"stationName is required."}""")
                "/error/api/v1/station-reports" -> Reply(500, """{"error":"server_error"}""")
                "/no-id/api/v1/station-reports" -> Reply(201, """{"status":"pending"}""")
                "/numeric-id/api/v1/station-reports" -> Reply(201, """{"id":42}""")
                "/redirect/api/v1/station-reports" -> Reply(307, "", "Location: /created/api/v1/station-reports\r\n")
                "/slow/api/v1/station-reports" -> { Thread.sleep(300); Reply(201, """{"id":"$submissionId"}""") }
                else -> Reply(404, """{"error":"not_found"}""")
            }
        }
        try {
            val base = "http://127.0.0.1:${server.port}"
            val report = payload(fullCorrection(), StationReports.location(35.6896, 139.7006, 8.0))
            fun client(mode: String, timeout: Int = 5_000) =
                StationReportClient("$base/$mode/api/v1/station-reports", allowLoopback = true, timeoutMillis = timeout)

            assertEquals(submissionId, client("created").submit(report))
            val sent = requests.single()
            assertEquals("POST", sent.method)
            assertEquals("application/json", sent.headers["content-type"])
            assertEquals("CardBal-Android/2.5.2", sent.headers["user-agent"])
            val body = Json.parseToJsonElement(sent.body.toString(Charsets.UTF_8)).jsonObject
            assertTrue(serverFields.containsAll(body.keys))
            assertEquals(submissionId, body.getValue("submissionId").jsonPrimitive.content)
            assertEquals(cardHash, body.getValue("cardIdHash").jsonPrimitive.content)
            assertEquals(deviceId, body.getValue("deviceId").jsonPrimitive.content)
            assertEquals("android", body.getValue("source").jsonPrimitive.content)

            // A retry reuses the submission ID; the server answers 200 for the duplicate.
            assertEquals(submissionId, client("duplicate").submit(report))
            assertEquals(requests[0].body.toList(), requests[1].body.toList())

            for (mode in listOf("invalid", "error", "no-id", "numeric-id", "redirect", "missing")) {
                assertThrows(mode, IOException::class.java) { client(mode).submit(report) }
            }
            assertTrue(requests.none { it.path.startsWith("/created") && it !== sent })
            // Plain HTTP is refused before connecting unless the loopback test override is set.
            val before = requests.size
            assertThrows(StationReportException::class.java) {
                StationReportClient("$base/created/api/v1/station-reports").submit(report)
            }
            assertEquals(before, requests.size)
            assertThrows(IOException::class.java) { client("slow", timeout = 50).submit(report) }
            assertEquals("https://cardbal.ieb.app/api/v1/station-reports", StationReports.ENDPOINT)
        } finally {
            server.close()
        }
    }

    private fun preferences(values: MutableMap<String, Any>): SharedPreferences {
        val editor = Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
            when (method.name) {
                "putString" -> { values[args[0] as String] = args[1]; proxy }
                "apply" -> null
                "commit" -> true
                else -> error(method.name)
            }
        } as SharedPreferences.Editor
        return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getString" -> values[args[0] as String] ?: args[1]
                "edit" -> editor
                else -> error(method.name)
            }
        } as SharedPreferences
    }

    private class Request(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)
    private data class Reply(val status: Int, val body: String, val headers: String = "")

    /** JDK-only HTTP stand-in on the loopback interface; nothing reaches the production endpoint. */
    private class LocalServer(private val handle: (Request) -> Reply) : AutoCloseable {
        private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port get() = socket.localPort
        @Volatile private var failure: Throwable? = null
        private val thread = Thread {
            while (!socket.isClosed) {
                try {
                    socket.accept().use { client ->
                        client.soTimeout = 2000
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
                        val headers = lines.drop(1).filter { ':' in it }.associate {
                            it.substringBefore(':').lowercase() to it.substringAfter(':').trim()
                        }
                        val body = ByteArray(headers["content-length"]?.toInt() ?: 0)
                        var position = 0
                        while (position < body.size) {
                            val count = input.read(body, position, body.size - position)
                            if (count < 0) error("Truncated HTTP body")
                            position += count
                        }
                        val requestLine = lines[0].split(' ')
                        val reply = handle(Request(requestLine[0], requestLine[1], headers, body))
                        val bytes = reply.body.toByteArray(Charsets.UTF_8)
                        val responseHeaders = "HTTP/1.1 ${reply.status} Test\r\nContent-Type: application/json\r\n" +
                            "Content-Length: ${bytes.size}\r\nConnection: close\r\n${reply.headers}\r\n"
                        // A timed-out caller may close before the injected delay ends.
                        try {
                            client.getOutputStream().write(responseHeaders.toByteArray() + bytes)
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
