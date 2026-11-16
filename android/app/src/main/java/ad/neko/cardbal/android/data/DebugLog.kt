package ad.neko.cardbal.android.data

import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * A short, rolling record of recent scan steps, kept on this device to help fix reading
 * problems, as on iPhone. It leaves the device only when the person taps Copy in Settings.
 *
 * Lines must never hold raw card responses or command payloads, session or device
 * identifiers, or the enquiry server address. Shorten card identifiers with [shortened].
 */
class DebugLog(
    private val file: File?,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    private val lock = Any()
    private val lines = ArrayDeque<String>()
    private var isLoaded = false
    private var isWriteScheduled = false
    private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS", Locale.ROOT)

    val isEmpty: Boolean
        get() = synchronized(lock) {
            loadIfNeeded()
            lines.isEmpty()
        }

    /** Adds one line. Cheap and never throws; the file is written shortly afterwards. */
    fun log(category: String, message: String) {
        val stamp = formatter.format(Instant.ofEpochMilli(clock()).atZone(zone))
        val schedule = synchronized(lock) {
            loadIfNeeded()
            lines.addLast("$stamp [${singleLine(category, 24)}] ${singleLine(message, MESSAGE_LIMIT)}")
            while (lines.size > LINE_LIMIT) lines.removeFirst()
            (file != null && !isWriteScheduled).also { if (it) isWriteScheduled = true }
        }
        if (schedule) writer.schedule({ persist() }, 500, TimeUnit.MILLISECONDS)
    }

    /** The recorded lines, oldest first. */
    fun text(): String = synchronized(lock) {
        loadIfNeeded()
        lines.joinToString("\n")
    }

    fun clear() {
        synchronized(lock) {
            isLoaded = true
            lines.clear()
        }
        if (file != null) writer.execute { persist() }
    }

    /** What Copy puts on the clipboard: a short header, then the lines. */
    fun exportText(environment: List<String>, details: List<String> = emptyList()): String =
        (listOf(TITLE) + environment + details + listOf("", text())).joinToString("\n") + "\n"

    /** Call with the lock held. */
    private fun loadIfNeeded() {
        if (isLoaded) return
        isLoaded = true
        val stored = file?.takeIf { it.isFile }?.let { runCatching { it.readText() }.getOrNull() } ?: return
        val merged = stored.split('\n').filter { it.isNotEmpty() } + lines
        lines.clear()
        lines.addAll(merged.takeLast(LINE_LIMIT))
    }

    private fun persist() {
        val contents = synchronized(lock) {
            isWriteScheduled = false
            lines.joinToString("\n")
        }
        val file = file ?: return
        runCatching {
            if (contents.isEmpty()) {
                file.delete()
                return
            }
            file.parentFile?.mkdirs()
            val pending = File(file.parentFile, "${file.name}.tmp")
            pending.writeText(contents)
            if (!pending.renameTo(file)) pending.delete()
        }
    }

    companion object {
        const val TITLE = "CardBal Debug Log"
        const val LINE_LIMIT = 600
        private const val MESSAGE_LIMIT = 400
        private val writer = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "cardbal-debug-log").apply { isDaemon = true }
        }

        /** In memory until [install] points it at the app's no-backup directory. */
        @Volatile
        var shared: DebugLog = DebugLog(null)
            private set

        fun install(noBackupFilesDir: File) {
            if (shared.file == null) shared = DebugLog(File(File(noBackupFilesDir, "DebugLog"), "debug-log.txt"))
        }

        fun log(category: String, message: String) = shared.log(category, message)

        /** Only the last four characters, e.g. "…1A2B", so a pasted log never holds a full card number. */
        fun shortened(identifier: String): String {
            val compact = identifier.filter { it.isLetterOrDigit() }
            return if (compact.isEmpty()) "(none)" else "…" + compact.takeLast(4)
        }

        fun shortened(identifier: ByteArray): String =
            shortened(identifier.joinToString("") { "%02X".format(it.toInt() and 0xff) })

        fun hex(byte: Int): String = "0x%02X".format(byte and 0xff)

        /** Exception type and message. Network errors give only their type, so no server address reaches the log. */
        fun describe(error: Throwable): String {
            val type = error.javaClass.simpleName.ifEmpty { error.javaClass.name }
            val network = error.javaClass.name.let { it.startsWith("java.net.") || it.startsWith("javax.net.") }
            val message = error.message?.takeIf { !network && it.isNotBlank() }
            return if (message == null) type else "$type: $message"
        }

        private fun singleLine(text: String, limit: Int): String {
            val result = text.replace("\r\n", " ").replace('\n', ' ').replace('\r', ' ')
            return if (result.length > limit) result.take(limit) + "…" else result
        }
    }
}
