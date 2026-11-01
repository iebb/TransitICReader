package ad.neko.cardbal.android.data

import org.junit.Assert.*
import org.junit.Test
import kotlinx.datetime.Instant

class ChineseCityCodesTest {
    @Test fun savedShanghaiCardsResolveTheirCityBeforeGenericBrands() {
        val oldCard = SavedCardRecord.from(TransitCardSnapshot(
            technology = "ISO7816", cardFamily = "City Union", identifierLabel = "UID",
            identifierValue = "SYNTHETIC", rawIdentifierValue = "SYNTHETIC",
            resultFields = listOf(ResultField("Brand", "City Union"), ResultField("Issuing City", "上海市")),
            scannedAt = Instant.parse("2026-11-01T00:00:00Z"),
        ))
        assertEquals("上海市", oldCard.displayTitle)
        assertEquals("上海市", oldCard.copy(issuingCity = "2000", resultFields = emptyList()).displayTitle)
        assertEquals("My card", oldCard.copy(customTitle = "My card").displayTitle)
        assertEquals("City Union", oldCard.copy(resultFields = emptyList()).displayTitle)
    }

    @Test fun shenzhenTerminalRuleRequiresItsCityAndRecordDiscriminator() {
        assertEquals("518068035001", ChineseCityCodes.shenzhenTravelTerminal("5840", "0000000268035001"))
        assertNull(ChineseCityCodes.shenzhenTravelTerminal("5180", "0000000268035001"))
        assertNull(ChineseCityCodes.shenzhenTravelTerminal("0344", "0000000268035001"))
        assertNull(ChineseCityCodes.shenzhenTravelTerminal("5840", "0000000368035001"))
        assertNull(ChineseCityCodes.shenzhenTravelTerminal("5840", "000000026803500100"))
        assertNull(ChineseCityCodes.shenzhenTravelTerminal("5840", "0000000268035ZZZ"))
    }
}
