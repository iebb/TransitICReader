package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.OctopusExchangeRate
import kotlinx.datetime.Instant
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.seconds

class DualCurrencyBalanceTest {
    private val scannedAt = Instant.parse("2026-10-31T12:00:00Z")
    private val rate = OctopusExchangeRate("0.839", OctopusExchangeRate.parseExpiry("202710311800"))

    private fun octopus(exchangeRate: OctopusExchangeRate?, at: Instant = scannedAt, balance: String? = "HK$50.0") = TransitCardSnapshot(
        technology = "FeliCa", cardFamily = "Octopus", identifierLabel = "IDm", identifierValue = "0102 0304 0506 0708",
        rawIdentifierValue = "0102030405060708", systemCode = "8008", balanceText = balance, realSerialNumber = "123456789",
        scannedAt = at, exchangeRate = exchangeRate,
    ).let { it.copy(applications = listOf(TransitApplication.from(it))) }

    private fun national(offset: Duration, balance: String? = "¥46.15") = TransitCardSnapshot(
        technology = "ISO7816", cardFamily = "China T-Union", identifierLabel = "UID", identifierValue = "01020304",
        rawIdentifierValue = "01020304", selectedAID = "A000000632010105", balanceText = balance,
        realSerialNumber = "3100000000000000001", scannedAt = scannedAt + offset,
    ).let { it.copy(applications = listOf(TransitApplication.from(it))) }

    private fun dual(vararg snapshots: TransitCardSnapshot) =
        DualCurrencyBalance.from(TransitApplication.combine(snapshots.toList())!!.applications, Locale.US)

    @Test fun combinedScanShowsBothBalancesAndTheRate() {
        val combined = TransitApplication.combine(listOf(national(2.seconds), octopus(rate)))!!
        assertEquals("0.839", combined.exchangeRate?.rate)
        assertEquals("HK$50.0", combined.balanceText)
        val dual = DualCurrencyBalance.from(combined.applications, Locale.US)!!
        assertEquals("CN¥46.15", dual.yuanBalance)
        assertEquals("HK$1 = CN¥0.839", dual.rateText)
        assertEquals(rate, dual.exchangeRate)
        // City Union cards carry the yuan balance when no national application is present.
        val cityUnion = national(1.seconds).let { snapshot ->
            snapshot.copy(selectedAID = "A00000000386980701", cardFamily = "City Union").let { it.copy(applications = listOf(TransitApplication.from(it))) }
        }
        assertEquals("CN¥46.15", dual(octopus(rate), cityUnion)!!.yuanBalance)
    }

    @Test fun yuanIsShownOnlyWhenReadWithinTwoMinutesOfTheHongKongBalance() {
        assertEquals(120.seconds, DualCurrencyBalance.SAME_SCAN_WINDOW)
        for (offset in listOf(Duration.ZERO, 120.seconds, (-120).seconds)) {
            assertEquals("$offset", "CN¥46.15", dual(octopus(rate), national(offset))!!.yuanBalance)
        }
        for (offset in listOf(121.seconds, (-121).seconds, (-1).hours)) {
            val stale = dual(octopus(rate), national(offset))
            assertNotNull("$offset", stale)
            assertNull("$offset", stale!!.yuanBalance)
        }
        // A missing T-Union side, an unread yuan balance or an unread HKD balance shows no yuan.
        assertNull(DualCurrencyBalance.from(octopus(rate).applications, Locale.US)!!.yuanBalance)
        assertNull(dual(octopus(rate), national(1.seconds, balance = null))!!.yuanBalance)
        assertNull(dual(octopus(rate, balance = null), national(1.seconds))!!.yuanBalance)
    }

    @Test fun cardsWithoutARateKeepASingleBalance() {
        assertNull(dual(octopus(null), national(1.seconds)))
        assertNull(DualCurrencyBalance.from(octopus(null).applications))
        assertNull(DualCurrencyBalance.from(national(Duration.ZERO).applications))
        assertNull(DualCurrencyBalance.from(null))
        assertNull(DualCurrencyBalance.from(emptyList()))
        assertNull(TransitApplication.combine(listOf(national(1.seconds), octopus(null)))!!.exchangeRate)
    }

    @Test fun expiredRateIsShownByDateAlone() {
        val expired = OctopusExchangeRate("0.839", OctopusExchangeRate.parseExpiry("202510311800"))
        val dual = dual(octopus(expired), national(1.seconds))!!
        assertTrue(dual.exchangeRate.isExpired())
        assertEquals("2025-10-31", dual.exchangeRate.expiryText(includeTime = false))
        // The rows still show both balances and the rate; only the expiry row changes.
        assertEquals("CN¥46.15", dual.yuanBalance)
        assertEquals("HK$1 = CN¥0.839", dual.rateText)
        val current = dual(octopus(rate), national(1.seconds))!!
        assertFalse(current.exchangeRate.isExpired(scannedAt))
        assertEquals("2027-10-31 18:00", current.exchangeRate.expiryText(includeTime = true))
    }

    @Test fun laterScansKeepTheRateButNotAStaleYuanBalance() {
        val saved = TransitApplication.combine(listOf(national(1.seconds), octopus(rate)))!!.applications!!
        // An Octopus-only rescan an hour later, with Octopus Online off, reports no rate.
        val rescan = octopus(null, at = scannedAt + 1.hours, balance = "HK$40.0").applications!!
        val merged = TransitApplication.merge(saved, rescan)
        assertEquals(rate, merged.single { it.isOctopus }.exchangeRate)
        val dual = DualCurrencyBalance.from(merged, Locale.US)!!
        assertNull(dual.yuanBalance)
        // A new rate from the rescan replaces the saved one.
        val newer = OctopusExchangeRate("0.85", null)
        assertEquals(newer, TransitApplication.merge(saved, octopus(newer, at = scannedAt + 1.hours).applications!!).single { it.isOctopus }.exchangeRate)
    }

    @Test fun yuanBalanceIsRelabelledAsCnyInEveryLocale() {
        for ((text, expected) in listOf("CN¥46.15" to "46.15", "¥46.15" to "46.15", "46,15 CN¥" to "46.15", "CN¥1,000.00" to "1000.00",
            "-¥1.50" to "-1.50", "CNY 32" to "32.00", "¥1.234,56" to "1234.56", "¥0.05" to "0.05")) {
            for (locale in listOf(Locale.US, Locale.JAPAN, Locale.KOREA, Locale.SIMPLIFIED_CHINESE, Locale.GERMANY)) {
                val yuan = DualCurrencyBalance.yuanText(text, locale)!!
                assertTrue("$text in $locale became $yuan", yuan.contains("CN¥"))
                assertFalse("$text in $locale became $yuan", yuan.replace("CN¥", "").contains("¥"))
                val digits = yuan.filter { it.isDigit() || it == '-' || it == '\u2212' }.replace('\u2212', '-')
                assertEquals("$text in $locale became $yuan", expected.filter { it.isDigit() || it == '-' }, digits)
            }
        }
        assertEquals("CN¥1,000.00", DualCurrencyBalance.yuanText("¥1000", Locale.US))
        for (unreadable in listOf("N/A", "", "¥", "CN¥.")) assertNull(unreadable, DualCurrencyBalance.yuanText(unreadable, Locale.US))
    }

    @Test fun rateIsSavedOnlyForCardsThatHaveOne() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val serializer = ListSerializer(TransitApplication.serializer())
        val combined = TransitApplication.combine(listOf(national(1.seconds), octopus(rate)))!!.applications!!
        val text = json.encodeToString(serializer, combined)
        assertEquals(combined, json.decodeFromString(serializer, text))
        val plain = json.encodeToString(serializer, octopus(null).applications!!)
        assertFalse(plain, plain.contains("exchangeRate"))
        assertNull(json.decodeFromString(serializer, plain).single().exchangeRate)
        // A saved rate without an expiry is still read back.
        val open = octopus(OctopusExchangeRate("0.84")).applications!!
        assertEquals(open, json.decodeFromString(serializer, json.encodeToString(serializer, open)))
    }
}
