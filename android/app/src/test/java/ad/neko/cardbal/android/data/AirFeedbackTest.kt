package ad.neko.cardbal.android.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.Base64
import java.util.Locale

class AirFeedbackTest {
    private val environment = AirFeedbackEnvironment(
        appVersion = "2.6.1", appBuild = "5", applicationId = "ad.neko.cardbal.android",
        deviceModel = "Google Pixel 9", osVersion = "16", osBuild = "BP2A.250605.031",
        architecture = "arm64-v8a", locale = "en_US",
    )

    private fun parse(bytes: ByteArray) = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject

    @Test fun feedbackBodyMatchesTheIphoneForm() {
        val body = parse(FeedbackClient.body("Hello", listOf(byteArrayOf(1, 2, 3)), environment))
        assertEquals(
            listOf("message", "appVersion", "appBuild", "deviceModel", "osVersion", "locale", "images"),
            body.keys.toList(),
        )
        assertEquals("Hello", body["message"]!!.jsonPrimitive.content)
        assertEquals("2.6.1", body["appVersion"]!!.jsonPrimitive.content)
        assertEquals("5", body["appBuild"]!!.jsonPrimitive.content)
        assertEquals("Google Pixel 9", body["deviceModel"]!!.jsonPrimitive.content)
        assertEquals("Android 16", body["osVersion"]!!.jsonPrimitive.content)
        assertEquals("en_US", body["locale"]!!.jsonPrimitive.content)
        val image = body["images"]!!.jsonArray.single().jsonObject
        assertEquals("image/jpeg", image["mediaType"]!!.jsonPrimitive.content)
        assertEquals(Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)), image["data"]!!.jsonPrimitive.content)
    }

    @Test fun feedbackBodyKeepsTheIngestLimits() {
        val images = List(6) { byteArrayOf(it.toByte()) }
        val body = parse(FeedbackClient.body("x".repeat(5000), images, environment))
        assertEquals(4000, body["message"]!!.jsonPrimitive.content.length)
        assertEquals(4, body["images"]!!.jsonArray.size)
        assertFalse(FeedbackClient.canSend("   ", 0))
        assertTrue(FeedbackClient.canSend("", 1))
        assertTrue(FeedbackClient.canSend("Hi", 0))
    }

    @Test fun localeUsesApplesIdentifierForm() {
        assertEquals("en_US", AirFeedbackEnvironment.appleLocaleIdentifier(Locale.US))
        assertEquals("zh-Hans_CN", AirFeedbackEnvironment.appleLocaleIdentifier(Locale.Builder().setLanguage("zh").setScript("Hans").setRegion("CN").build()))
        assertEquals("ja", AirFeedbackEnvironment.appleLocaleIdentifier(Locale.JAPANESE))
    }

    @Test fun crashReportCarriesTheExceptionAndItsCauses() {
        val cause = IllegalArgumentException("bad input")
        val error = IllegalStateException("outer failure", cause)
        error.stackTrace = arrayOf(
            StackTraceElement("ad.neko.cardbal.android.MainActivity", "onCreate", "MainActivity.kt", 42),
            StackTraceElement("android.app.Activity", "performCreate", "Activity.java", 8000),
            StackTraceElement("dalvik.system.VMStack", "getThreadStackTrace", null, -2),
        )
        cause.stackTrace = arrayOf(StackTraceElement("ad.neko.cardbal.android.data.Parser", "parse", "Parser.kt", 7))
        val report = CrashReport.of(error, "main", 1_763_312_075_611, "install-1", environment, id = "report-1")
        val json = parse(CrashReport.encoded(report)!!)

        assertEquals("report-1", json["id"]!!.jsonPrimitive.content)
        assertEquals("2025-11-16T16:54:35.611Z", json["occurredAt"]!!.jsonPrimitive.content)
        assertEquals("install-1", json["installID"]!!.jsonPrimitive.content)
        assertEquals("ad.neko.cardbal.android", json["app"]!!.jsonObject["bundleID"]!!.jsonPrimitive.content)
        val device = json["device"]!!.jsonObject
        assertEquals("Android", device["os"]!!.jsonPrimitive.content)
        assertEquals("BP2A.250605.031", device["osBuild"]!!.jsonPrimitive.content)
        assertEquals("arm64-v8a", device["arch"]!!.jsonPrimitive.content)

        val exception = json["exception"]!!.jsonObject
        // Mach type, code and signal have no JVM meaning: explicit nulls, as the iPhone sends them.
        assertEquals(JsonNull, exception["type"])
        assertEquals(JsonNull, exception["code"])
        assertEquals(JsonNull, exception["signal"])
        assertEquals("java.lang.IllegalStateException", exception["name"]!!.jsonPrimitive.content)
        assertEquals("outer failure", exception["message"]!!.jsonPrimitive.content)
        assertEquals(
            "Uncaught exception in thread \"main\"; caused by java.lang.IllegalArgumentException: bad input",
            exception["terminationReason"]!!.jsonPrimitive.content,
        )

        val threads = json["threads"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf(true, false), threads.map { it["crashed"]!!.jsonPrimitive.boolean })
        val frames = threads[0]["frames"]!!.jsonArray.map { it.jsonObject }
        assertEquals("ad.neko.cardbal.android", frames[0]["image"]!!.jsonPrimitive.content)
        assertEquals(CrashReport.imageUUID("ad.neko.cardbal.android"), frames[0]["uuid"]!!.jsonPrimitive.content)
        assertEquals(42L, frames[0]["offset"]!!.jsonPrimitive.long)
        assertFalse(frames[0]["inApp"]!!.jsonPrimitive.boolean)
        assertEquals("ad.neko.cardbal.android.MainActivity.onCreate(MainActivity.kt:42)", frames[0]["symbol"]!!.jsonPrimitive.content)
        assertEquals(0, frames[0]["symbolOffset"]!!.jsonPrimitive.int)
        assertEquals("dalvik.system.VMStack.getThreadStackTrace(Native Method)", frames[2]["symbol"]!!.jsonPrimitive.content)
        assertEquals(0L, frames[2]["offset"]!!.jsonPrimitive.long)

        val images = json["images"]!!.jsonArray.map { it.jsonObject["name"]!!.jsonPrimitive.content }
        assertEquals(listOf("ad.neko.cardbal.android", "android.app", "dalvik.system", "ad.neko.cardbal.android.data"), images)
    }

    @Test fun crashWithoutFramesIsNotSentAndOversizedReportsAreTrimmed() {
        val empty = RuntimeException("no stack").apply { stackTrace = emptyArray() }
        assertNull(CrashReport.encoded(CrashReport.of(empty, "main", 0, "i", environment)))

        // Nine exceptions of long frames: well over the ingest's size before trimming.
        fun frames(prefix: String) = Array(256) { StackTraceElement("p$it.C${"x".repeat(1100)}", "$prefix$it", "C.kt", it) }
        var huge: Throwable = RuntimeException("x".repeat(2000)).apply { stackTrace = frames("root") }
        repeat(8) { level -> huge = RuntimeException("level $level", huge).apply { stackTrace = frames("l$level") } }
        val report = CrashReport.of(huge, "main", 0, "i", environment)
        assertEquals(9, report.threads.size)
        val body = CrashReport.encoded(report)!!
        assertTrue(body.size <= AirCrashReports.MAXIMUM_BODY)
        val threads = parse(body)["threads"]!!.jsonArray
        assertTrue(threads.size in 1 until 9)
        assertTrue(threads[0].jsonObject["crashed"]!!.jsonPrimitive.boolean)
        assertEquals("level 7", parse(body)["exception"]!!.jsonObject["message"]!!.jsonPrimitive.content)

        val long = RuntimeException("x".repeat(2000)).apply { stackTrace = arrayOf(frames("long")[0]) }
        val message = CrashReport.of(long, "main", 0, "i", environment).exception.message!!
        assertEquals(1024, message.length)
    }

    @Test fun queueKeepsTheNewestTwentyAndSendsOldestFirst() {
        val folder = Files.createTempDirectory("air-crash").toFile()
        try {
            val queue = CrashQueue(folder)
            repeat(25) { queue.enqueue("{\"n\":$it}".toByteArray(), "id-$it", 1_000L + it) }
            val names = queue.queued().map { it.name }
            assertEquals(AirCrashReports.MAXIMUM_QUEUED, names.size)
            assertEquals("000000000001005-id-5.json", names.first())

            val sent = mutableListOf<String>()
            val statuses = ArrayDeque(listOf(201, 202, 500, 400, 408))
            queue.sendPass(post = { body ->
                sent += body.toString(Charsets.UTF_8)
                AirFeedbackTransport.Response(statuses.removeFirstOrNull() ?: 201, "", null)
            }) { error("not deferred") }
            assertEquals(20, sent.size)
            assertEquals("{\"n\":5}", sent.first())
            // 500 and 408 stay for the next launch; everything else is gone.
            assertEquals(listOf("{\"n\":7}", "{\"n\":9}"), queue.queued().map { it.readText() })
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test fun rateLimitOrNoNetworkEndsThePass() {
        val folder = Files.createTempDirectory("air-crash").toFile()
        try {
            val queue = CrashQueue(folder)
            repeat(3) { queue.enqueue("{}".toByteArray(), "id-$it", it.toLong()) }
            var deferredUntil = 0L
            var posts = 0
            queue.sendPass(post = { posts++; AirFeedbackTransport.Response(429, "", "120") }) { deferredUntil = it }
            assertEquals(1, posts)
            assertTrue(deferredUntil > System.currentTimeMillis() + 100_000)
            assertEquals(3, queue.queued().size)

            posts = 0
            queue.sendPass(post = { posts++; throw java.io.IOException("offline") }) { error("not deferred") }
            assertEquals(1, posts)
            assertEquals(3, queue.queued().size)
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test fun serverReasonIsShownWhenGiven() {
        val error = AirFeedbackException(422, "Message is too long.")
        assertEquals("Message is too long.", error.message)
        assertEquals("The server answered 500.", AirFeedbackException(500, null).message)
        assertTrue(Json.parseToJsonElement("{\"reason\":\"x\"}") is JsonObject)
    }
}
