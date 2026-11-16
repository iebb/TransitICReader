package ad.neko.cardbal.android.data

import android.content.Context
import android.os.Build
import ad.neko.cardbal.android.BuildConfig
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.Locale
import java.util.UUID

/**
 * AirFeedback, where the iPhone app's Send Feedback form and crash reports go: the same
 * endpoints and public ingestion key. The key can only submit reports, so it may ship in the
 * app. Android sends no device proof, so its reports are stored as unverified.
 */
object AirFeedbackConfig {
    const val FEEDBACK_ENDPOINT = "https://apps.air.build/v1/ingest/feedback"
    const val CRASH_ENDPOINT = "https://apps.air.build/v1/ingest/crashes"
    const val APP_KEY = "ak_production_CtdudKWcYsxEATS94tSaG81ARdc3LzCRpymZoDpaNVw"
    const val MAXIMUM_IMAGES = 4
    const val MAXIMUM_MESSAGE_LENGTH = 4000
}

/** What a report says about the app and device: no account and no device identifier. */
data class AirFeedbackEnvironment(
    val appVersion: String,
    val appBuild: String,
    val applicationId: String,
    /** `Google Pixel 9`: the manufacturer and model, which is what a bug report needs. */
    val deviceModel: String,
    /** `16`, the Android release. */
    val osVersion: String,
    /** The system build id, such as `BP2A.250605.031`. */
    val osBuild: String,
    val architecture: String,
    /** Apple's form, as the iPhone app sends it: `en_US`, `zh-Hans_CN`. */
    val locale: String,
) {
    companion object {
        fun current(): AirFeedbackEnvironment {
            val model = Build.MODEL.orEmpty().trim()
            val manufacturer = Build.MANUFACTURER.orEmpty().trim().replaceFirstChar { it.titlecase(Locale.ROOT) }
            return AirFeedbackEnvironment(
                appVersion = BuildConfig.VERSION_NAME,
                appBuild = BuildConfig.VERSION_CODE.toString(),
                applicationId = BuildConfig.APPLICATION_ID,
                deviceModel = if (manufacturer.isEmpty() || model.startsWith(manufacturer, ignoreCase = true)) model
                    else "$manufacturer $model",
                osVersion = Build.VERSION.RELEASE.orEmpty(),
                osBuild = Build.ID.orEmpty(),
                architecture = Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                locale = appleLocaleIdentifier(Locale.getDefault()),
            )
        }

        fun appleLocaleIdentifier(locale: Locale): String = buildString {
            append(locale.language.ifEmpty { "en" })
            if (locale.script.isNotEmpty()) append('-').append(locale.script)
            if (locale.country.isNotEmpty()) append('_').append(locale.country)
        }
    }
}

/** The server refused a report: [reason] is its explanation when it gave one. */
class AirFeedbackException(val status: Int, val reason: String?) :
    IOException(reason ?: "The server answered $status.")

/** One POST with the public key, as the iPhone app makes it; returns the status and Retry-After. */
internal class AirFeedbackTransport(
    private val appKey: String = AirFeedbackConfig.APP_KEY,
    private val userAgent: String = "CardBal-Android/${BuildConfig.VERSION_NAME}",
    private val timeoutMillis: Int = 60_000,
) {
    data class Response(val status: Int, val body: String, val retryAfter: String?)

    fun post(endpoint: String, body: ByteArray): Response {
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.useCaches = false
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Authorization", "Bearer $appKey")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("User-Agent", userAgent)
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (output.size() < MAX_RESPONSE_BYTES) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            }.orEmpty()
            return Response(status, text, connection.getHeaderField("Retry-After"))
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val MAX_RESPONSE_BYTES = 65_536
    }
}

/**
 * The Send Feedback form's client: the same JSON body as the iPhone app's AppFeedback.swift
 * (`message`, `appVersion`, `appBuild`, `deviceModel`, `osVersion`, `locale`, and `images` as
 * base64 JPEG), posted to the feedback endpoint with `Authorization: Bearer <key>`.
 */
class FeedbackClient internal constructor(
    private val endpoint: String = AirFeedbackConfig.FEEDBACK_ENDPOINT,
    private val transport: AirFeedbackTransport = AirFeedbackTransport(),
) {
    constructor() : this(AirFeedbackConfig.FEEDBACK_ENDPOINT, AirFeedbackTransport())

    /** Blocking: call it off the main thread. Throws [AirFeedbackException] or another [IOException]. */
    fun send(message: String, jpegImages: List<ByteArray>, environment: AirFeedbackEnvironment) {
        val response = transport.post(endpoint, body(message, jpegImages, environment))
        if (response.status !in 200..299) {
            val reason = runCatching {
                ((Json.parseToJsonElement(response.body) as? JsonObject)?.get("reason") as? JsonPrimitive)
                    ?.takeIf { it.isString }?.content
            }.getOrNull()
            throw AirFeedbackException(response.status, reason?.takeIf { it.isNotBlank() })
        }
    }

    companion object {
        internal fun body(message: String, jpegImages: List<ByteArray>, environment: AirFeedbackEnvironment): ByteArray =
            buildJsonObject {
                put("message", message.take(AirFeedbackConfig.MAXIMUM_MESSAGE_LENGTH))
                put("appVersion", environment.appVersion)
                put("appBuild", environment.appBuild)
                put("deviceModel", environment.deviceModel)
                put("osVersion", "Android ${environment.osVersion}")
                put("locale", environment.locale)
                putJsonArray("images") {
                    jpegImages.take(AirFeedbackConfig.MAXIMUM_IMAGES).forEach { image ->
                        addJsonObject {
                            put("mediaType", "image/jpeg")
                            put("data", Base64.getEncoder().encodeToString(image))
                        }
                    }
                }
            }.toString().toByteArray(Charsets.UTF_8)

        fun canSend(message: String, imageCount: Int): Boolean = message.isNotBlank() || imageCount > 0
    }
}

/**
 * Crash reports for AirFeedback, like the iPhone app's AirCrashReports.swift: an uncaught
 * exception is written to disk as one report, the previous handler (Android's, which ends the
 * app) runs as before, and the next launch sends it. At most [MAXIMUM_QUEUED] wait on disk.
 *
 * A report holds a random report id, when it happened, a random per-install id (only for
 * counting affected installs), the app's version, build and application id, the device model,
 * Android version and build, ABI and locale, and the exception: its class, message, causes and
 * stack frames. No account, card data or files.
 */
object AirCrashReports {
    const val MAXIMUM_QUEUED = 20
    /** Under the ingest's 512 KiB, with room for headers. */
    const val MAXIMUM_BODY = 500_000
    private const val PREFERENCES = "air_crash_reports"
    private const val INSTALL_ID_KEY = "installID"
    private const val NOT_BEFORE_KEY = "notBefore"
    private var installed = false

    /** Installs the handler once and sends what earlier launches left queued. */
    fun start(context: Context) {
        val app = context.applicationContext
        val preferences = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val queue = CrashQueue(File(app.noBackupFilesDir, "AirCrashReports"))
        synchronized(this) {
            if (installed) return
            installed = true
        }
        val installID = preferences.getString(INSTALL_ID_KEY, null)?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }
            ?: UUID.randomUUID().toString().also { preferences.edit().putString(INSTALL_ID_KEY, it).apply() }
        val environment = AirFeedbackEnvironment.current()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            // Never let the report stop Android's own crash handling.
            runCatching {
                val report = CrashReport.of(error, thread.name, System.currentTimeMillis(), installID, environment)
                CrashReport.encoded(report)?.let { queue.enqueue(it, report.id, System.currentTimeMillis()) }
            }
            if (previous != null) {
                previous.uncaughtException(thread, error)
            } else {
                android.os.Process.killProcess(android.os.Process.myPid())
                kotlin.system.exitProcess(10)
            }
        }
        Thread({
            runCatching {
                val notBefore = preferences.getLong(NOT_BEFORE_KEY, 0)
                if (notBefore > System.currentTimeMillis()) return@runCatching
                val transport = AirFeedbackTransport(timeoutMillis = 30_000)
                queue.sendPass(post = { transport.post(AirFeedbackConfig.CRASH_ENDPOINT, it) }) { retryAt ->
                    preferences.edit().putLong(NOT_BEFORE_KEY, retryAt).apply()
                }
            }
        }, "AirCrashReports").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }.start()
    }
}

/** One crash, as `POST /v1/ingest/crashes` takes it (the iPhone app's `Report`). */
@Serializable
internal data class CrashReport(
    val id: String,
    val occurredAt: String,
    val installID: String,
    val app: App,
    val device: Device,
    val exception: Exception,
    val threads: List<Thread>,
    val images: List<Image>,
) {
    @Serializable data class App(val version: String, val build: String, val bundleID: String)

    @Serializable data class Device(
        val model: String, val os: String, val osVersion: String, val osBuild: String, val arch: String, val locale: String,
    )

    /** MetricKit's Mach exception type, code and signal have no JVM equivalent: sent as null. */
    @Serializable data class Exception(
        val type: Int?, val code: Int?, val signal: Int?, val name: String?, val message: String?, val terminationReason: String?,
    )

    @Serializable data class Thread(val crashed: Boolean, val frames: List<Frame>)

    /**
     * A JVM frame in the ingest's terms: the class's package is the image (with a stable
     * name-based UUID) and the line number the offset. `symbol` carries the readable frame.
     * Frames are sent as not in-app: the server would otherwise wait for a dSYM for them and
     * drop the symbol, and Android has no dSYMs.
     */
    @Serializable data class Frame(
        val image: String, val uuid: String, val offset: Long, val inApp: Boolean, val symbol: String, val symbolOffset: Long,
    )

    @Serializable data class Image(val name: String, val uuid: String, val inApp: Boolean)

    companion object {
        private val json = Json { encodeDefaults = true }
        private val timestamp = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).withZone(ZoneOffset.UTC)
        private const val MAXIMUM_CAUSES = 8

        fun of(
            error: Throwable,
            threadName: String,
            occurredAtMillis: Long,
            installID: String,
            environment: AirFeedbackEnvironment,
            id: String = UUID.randomUUID().toString(),
        ): CrashReport {
            val chain = generateSequence(error) { it.cause?.takeIf { cause -> cause !== it } }
                .take(MAXIMUM_CAUSES + 1).toList()
            // The thrown exception's stack first (up to 256 frames), then each cause's (up to 64).
            val threads = chain.mapIndexedNotNull { index, throwable ->
                val frames = throwable.stackTrace.take(if (index == 0) 256 else 64).map(::frame)
                if (frames.isEmpty()) null else Thread(crashed = index == 0, frames = frames)
            }
            val causes = chain.drop(1).joinToString("") { cause ->
                "; caused by ${cause.javaClass.name}" + (cause.message?.let { ": ${singleLine(it)}" } ?: "")
            }
            return CrashReport(
                id = id,
                occurredAt = timestamp.format(Instant.ofEpochMilli(occurredAtMillis)),
                installID = installID,
                app = App(environment.appVersion, environment.appBuild, environment.applicationId),
                device = Device(
                    model = environment.deviceModel, os = "Android", osVersion = environment.osVersion,
                    osBuild = environment.osBuild, arch = environment.architecture, locale = environment.locale,
                ),
                exception = Exception(
                    type = null, code = null, signal = null,
                    name = error.javaClass.name.take(256),
                    message = error.message?.takeIf { it.isNotEmpty() }?.take(1024),
                    terminationReason = "Uncaught exception in thread \"${singleLine(threadName)}\"$causes".take(512),
                ),
                threads = threads,
                images = images(threads),
            )
        }

        /** The JSON body, trimmed like the iPhone's: threads from the end, then the deepest frames. */
        fun encoded(report: CrashReport): ByteArray? {
            if (report.threads.isEmpty()) return null // the ingest refuses a crash without a frame
            var current = report
            while (true) {
                val body = json.encodeToString(serializer(), current).toByteArray(Charsets.UTF_8)
                val frames = current.threads.sumOf { it.frames.size }
                if (body.size <= AirCrashReports.MAXIMUM_BODY || frames <= 1) return body
                val threads = if (current.threads.size > 1) {
                    current.threads.dropLast(maxOf(1, (current.threads.size - 1) / 4))
                } else {
                    val first = current.threads[0]
                    listOf(first.copy(frames = first.frames.dropLast(maxOf(1, frames / 4))))
                }
                current = current.copy(threads = threads, images = images(threads))
            }
        }

        private fun frame(element: StackTraceElement): Frame {
            val image = element.className.substringBeforeLast('.', "").ifEmpty { element.className }.take(256)
            val location = when {
                element.isNativeMethod -> "Native Method"
                element.fileName == null -> "Unknown Source"
                element.lineNumber >= 0 -> "${element.fileName}:${element.lineNumber}"
                else -> element.fileName
            }
            return Frame(
                image = image,
                uuid = imageUUID(image),
                offset = element.lineNumber.coerceAtLeast(0).toLong(),
                inApp = false,
                symbol = "${element.className}.${element.methodName}($location)".take(1024),
                symbolOffset = 0,
            )
        }

        fun imageUUID(image: String): String =
            UUID.nameUUIDFromBytes("jvm:$image".toByteArray(Charsets.UTF_8)).toString().uppercase(Locale.ROOT)

        private fun images(threads: List<Thread>): List<Image> =
            threads.flatMap { it.frames }.map { Image(it.image, it.uuid, it.inApp) }.distinct()

        private fun singleLine(text: String): String = text.replace(Regex("\\s+"), " ").trim().take(256)
    }
}

/** Reports waiting to be sent, one exact JSON body per file, oldest first by name. */
internal class CrashQueue(private val folder: File) {
    /** Writes one report and drops the oldest beyond [AirCrashReports.MAXIMUM_QUEUED]. */
    fun enqueue(json: ByteArray, id: String, nowMillis: Long) {
        folder.mkdirs()
        val name = nowMillis.coerceAtLeast(0).toString().padStart(15, '0') + "-" + id + ".json"
        val temporary = File(folder, "$name.tmp")
        temporary.writeBytes(json)
        if (!temporary.renameTo(File(folder, name))) temporary.delete()
        queued().dropLast(AirCrashReports.MAXIMUM_QUEUED).forEach { it.delete() }
    }

    fun queued(): List<File> =
        folder.listFiles { file -> file.isFile && file.name.endsWith(".json") }.orEmpty().sortedBy { it.name }

    /**
     * Posts each queued report once, oldest first. Accepted (2xx, including 202 when the owner
     * has crash reports off) or refused for good (4xx) deletes it; 408, 5xx and other answers keep
     * it for the next launch. No network, or 429, ends the pass: the rest would fare the same.
     */
    fun sendPass(post: (ByteArray) -> AirFeedbackTransport.Response, deferUntil: (Long) -> Unit) {
        for (file in queued()) {
            val body = runCatching { file.readBytes() }.getOrNull() ?: continue
            val response = runCatching { post(body) }.getOrNull() ?: return
            when (response.status) {
                in 200..299, in 400..407, in 409..428, in 430..499 -> file.delete()
                429 -> {
                    val seconds = response.retryAfter?.trim()?.toLongOrNull() ?: 60
                    deferUntil(System.currentTimeMillis() + seconds.coerceIn(1, 86_400) * 1000)
                    return
                }
                else -> Unit
            }
        }
    }
}
