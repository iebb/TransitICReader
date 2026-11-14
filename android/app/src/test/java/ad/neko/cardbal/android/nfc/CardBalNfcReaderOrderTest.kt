package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.DualCurrencyBalance
import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.data.TransitCardSnapshot
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

/** City Union / T-Union are read before the local reader, as in 2.5.2. Invented bytes only. */
class CardBalNfcReaderOrderTest {
    private val cityUnion = "A00000000386980701"
    private val shenzhen = ChineseLocalProtocol.Kind.Shenzhen.aids.single()
    private val ticl = ChineseLocalProtocol.LINGNAN_PURSE_AID
    private val appy = ChineseLocalProtocol.LINGNAN_INFO_AID
    private val localNames = ChineseLocalProtocol.Kind.entries.flatMap { it.aids }.toSet()
    private val scannedAt = Instant.parse("2026-11-01T00:00:00Z")

    /** Answers only the listed applications; everything else is 6A82. */
    private fun card(applications: Set<String>, selects: MutableList<String>): (ByteArray) -> ByteArray {
        var selected = ""
        val metadata = ByteArray(30).also { it[2] = 0x20; it[19] = 1 }
        return { command ->
            val instruction = command[1].toInt() and 255
            when {
                instruction == 0xA4 && command[2] == 4.toByte() -> {
                    val name = command.copyOfRange(5, 5 + (command[4].toInt() and 255)).hexString()
                    selects.add(name)
                    if (name in applications) { selected = name; "9000".hexToBytes() } else "6A82".hexToBytes()
                }
                instruction == 0x5C && command[2] == 0.toByte() && selected == cityUnion -> "000030399000".hexToBytes()
                instruction == 0x5C && command[2] == 0.toByte() && selected == shenzhen -> "800004D29000".hexToBytes()
                instruction == 0x5C && command[2] == 0.toByte() && selected == ticl -> "00000BB89000".hexToBytes()
                instruction == 0xB0 && command[2] == 0x95.toByte() && selected == appy ->
                    "000000000000000001010051234567890000000020200101203012310000".hexToBytes() + "9000".hexToBytes()
                instruction == 0xB0 && command[2] == 0x95.toByte() && selected == cityUnion -> metadata + "9000".hexToBytes()
                instruction == 0xB0 && command[2] == 0x95.toByte() && selected == shenzhen ->
                    "0000000000000000000000000000000015CD5B07202501012030123100000000".hexToBytes() + "9000".hexToBytes()
                else -> "6A82".hexToBytes()
            }
        }
    }

    private fun scan(applications: Set<String>, selects: MutableList<String>, calls: MutableList<String>,
                     octopus: TransitCardSnapshot? = null): List<TransitCardSnapshot> {
        val exchange = card(applications, selects)
        val decoders = CardBalNfcReader.orderedDecoders(ClipperLookup.Numeric, null)
        return CardBalNfcReader.read(decoders) { decoder ->
            calls.add(decoder::class.simpleName!!)
            when (decoder) {
                is Iso7816Decoder -> Iso7816Protocol.select(cityUnion, exchange)?.let { decoder.readApplication("01020304", it, scannedAt, exchange) }
                is ChineseLocalDecoder -> ChineseLocalDecoder.read("01020304", scannedAt, exchange)
                is JapaneseICDecoder -> octopus
                else -> null
            }
        }
    }

    @Test fun iso7816IsReadBeforeTheLocalReader() {
        val order = CardBalNfcReader.orderedDecoders(ClipperLookup.Numeric, null).map { it::class.simpleName }
        assertEquals(listOf("CEPASDecoder", "MacauPassDecoder", "ClipperDecoder", "ClipperUltralightDecoder", "StoredValueDecoder",
            "CalypsoDecoder", "Iso7816Decoder", "ChineseLocalDecoder", "JapaneseICDecoder"), order)
        assertTrue(order.indexOf("Iso7816Decoder") < order.indexOf("ChineseLocalDecoder"))
    }

    @Test fun cityUnionOnlyCardIsReadByTheCityUnionReaderUndisturbed() {
        val selects = mutableListOf<String>(); val calls = mutableListOf<String>()
        val results = scan(setOf(cityUnion), selects, calls)
        assertTrue(calls.indexOf("Iso7816Decoder") < calls.indexOf("ChineseLocalDecoder"))
        // No local SELECT reached the card before the City Union read finished.
        val firstLocal = selects.indexOfFirst { it in localNames }
        assertTrue(firstLocal > 0 && selects.take(firstLocal).all { it == cityUnion })
        val snapshot = TransitApplication.combine(results)!!
        assertEquals(1, results.size)
        assertEquals(cityUnion, snapshot.selectedAID)
        assertTrue(snapshot.applications!!.single().isCityUnion)
        assertNotNull(snapshot.balanceText)
    }

    @Test fun localApplicationBesideCityUnionKeepsBothViewsWithCityUnionPrimary() {
        val selects = mutableListOf<String>(); val calls = mutableListOf<String>()
        val results = scan(setOf(cityUnion, shenzhen), selects, calls)
        assertEquals(2, results.size)
        val (mainland, local) = results
        assertEquals("Shenzhen Tong", local.cardFamily)
        val snapshot = TransitApplication.combine(results)!!
        val apps = snapshot.applications!!
        assertEquals(2, apps.size)
        assertTrue(apps.any { it.isCityUnion })
        assertTrue(apps.any { it.cardFamily == "Shenzhen Tong" && it.selectedAID == shenzhen })
        assertEquals(cityUnion, snapshot.selectedAID)
        assertEquals(mainland.cardFamily, snapshot.cardFamily)
        assertEquals(mainland.balanceText, snapshot.balanceText)
        assertNotEquals(local.balanceText, snapshot.balanceText)
    }

    private fun octopus(rate: OctopusExchangeRate? = null) = TransitCardSnapshot(
        technology = "FeliCa", cardFamily = "Octopus", identifierLabel = "IDm", identifierValue = "0102030405060708",
        rawIdentifierValue = "0102030405060708", systemCode = "8008", balanceText = "HK$50.0", scannedAt = scannedAt, exchangeRate = rate,
    ).let { it.copy(applications = listOf(TransitApplication.from(it))) }

    @Test fun lingnanOnlyCardIsReadAfterCityUnionAndTUnionDeclined() {
        val selects = mutableListOf<String>(); val calls = mutableListOf<String>()
        val results = scan(setOf(appy, ticl), selects, calls)
        assertEquals(1, results.size)
        val snapshot = TransitApplication.combine(results)!!
        assertEquals("Lingnan Pass", snapshot.cardFamily)
        assertEquals(ticl, snapshot.selectedAID)
        assertEquals("5123456789", snapshot.realSerialNumber)
        assertTrue(snapshot.applications!!.single().isLingnan)
        assertTrue(calls.indexOf("Iso7816Decoder") < calls.indexOf("ChineseLocalDecoder"))
        // A Lingnan-only card has no Octopus side; nothing else is invented.
        assertEquals("JapaneseICDecoder", calls.last())
    }

    @Test fun lingnanBesideOctopusIsOneCardWithTwoViews() {
        for (rate in listOf(null, OctopusExchangeRate("0.839", null))) {
            val results = scan(setOf(appy, ticl), mutableListOf(), mutableListOf(), octopus(rate))
            assertEquals(2, results.size)
            val snapshot = TransitApplication.combine(results)!!
            val apps = snapshot.applications!!
            assertEquals(2, apps.size)
            assertTrue(apps.any { it.isOctopus } && apps.any { it.isLingnan })
            assertEquals("Octopus + Lingnan Pass", snapshot.cardFamily)
            assertEquals("HK$50.0", snapshot.balanceText)
            // The separate Lingnan purse is never shown as the CN¥ side of an Octopus – T-Union card.
            assertNull(DualCurrencyBalance.from(apps)?.yuanBalance)
        }
    }

    @Test fun shenzhenBesideOctopusStillDoesNotPair() {
        val results = scan(setOf(shenzhen), mutableListOf(), mutableListOf(), octopus())
        assertEquals(1, results.size)
        assertEquals("Shenzhen Tong", results.single().cardFamily)
    }
}
