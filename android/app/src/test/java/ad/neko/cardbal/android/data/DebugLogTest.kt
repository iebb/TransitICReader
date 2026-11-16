package ad.neko.cardbal.android.data

import java.io.File
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DebugLogTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun memoryLog() = DebugLog(null, clock = { 1_762_000_000_123 }, zone = ZoneOffset.UTC)

    @Test fun linesAreTimestampedSingleLineAndBounded() {
        val log = memoryLog()
        log.log("A category longer than twenty-four", "first\nsecond\r\nthird" + "x".repeat(500))
        val line = log.text()
        assertTrue(line.startsWith("2025-11-01 12:26:40.123 [A category longer than t…] first second third"))
        assertFalse('\n' in line)
        assertTrue(line.endsWith("x…"))
        assertEquals(400, line.substringAfter("] ").length - 1)
    }

    @Test fun keepsOnlyTheMostRecentLines() {
        val log = memoryLog()
        repeat(DebugLog.LINE_LIMIT + 5) { log.log("Scan", "line $it") }
        val lines = log.text().split('\n')
        assertEquals(DebugLog.LINE_LIMIT, lines.size)
        assertTrue(lines.first().endsWith("line 5"))
        assertTrue(lines.last().endsWith("line ${DebugLog.LINE_LIMIT + 4}"))
    }

    @Test fun exportHasHeaderThenLinesAndClearEmptiesIt() {
        val log = memoryLog()
        assertTrue(log.isEmpty)
        log.log("Scan", "Finished")
        val export = log.exportText(listOf("App: 1 (2)", "System: Android", "Device: Test"), listOf("Octopus Online: off"))
        assertEquals(
            listOf("CardBal Debug Log", "App: 1 (2)", "System: Android", "Device: Test", "Octopus Online: off", ""),
            export.split('\n').take(6),
        )
        assertTrue(export.endsWith("[Scan] Finished\n"))
        log.clear()
        assertTrue(log.isEmpty)
    }

    @Test fun persistsAcrossInstancesAndRemovesTheFileWhenCleared() {
        val file = File(temporary.root, "DebugLog/debug-log.txt")
        val log = DebugLog(file)
        log.log("Scan", "kept")
        waitFor { file.isFile }
        assertTrue(DebugLog(file).text().endsWith("[Scan] kept"))
        log.clear()
        waitFor { !file.exists() }
        assertTrue(DebugLog(file).isEmpty)
    }

    @Test fun shortensIdentifiersAndHidesNetworkMessages() {
        assertEquals("…1A2B", DebugLog.shortened("0123 4567 89AB 1A2B"))
        assertEquals("…0D0E", DebugLog.shortened(byteArrayOf(0x0a, 0x0b, 0x0c, 0x0d, 0x0e)))
        assertEquals("(none)", DebugLog.shortened(" - "))
        assertEquals("0x9A", DebugLog.hex(0x9a))
        assertEquals("UnknownHostException", DebugLog.describe(java.net.UnknownHostException("enquiry.example")))
        assertEquals("IOException: Tag was lost.", DebugLog.describe(java.io.IOException("Tag was lost.")))
    }

    private fun waitFor(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "Timed out" }
            Thread.sleep(20)
        }
    }
}
