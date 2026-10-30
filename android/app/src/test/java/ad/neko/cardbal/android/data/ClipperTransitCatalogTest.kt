package ad.neko.cardbal.android.data

import org.junit.Assert.*
import org.junit.Test

class ClipperTransitCatalogTest {
    @Test fun pinnedCatalogResolvesAgencyStationsAndMapLocations() {
        val text = javaClass.classLoader!!.getResourceAsStream("ClipperTransit.json")!!
            .bufferedReader().use { it.readText() }
        val catalog = ClipperTransitCatalog.fromJson(text)
        assertEquals("Bay Area Rapid Transit", catalog.agencyName(4))
        assertEquals("Alum Rock", catalog.stationName(17, 5, false))
        val code = catalog.stationCode(17, 5)
        assertEquals("CLIPPER:1114117", code)
        val point = catalog.point(code)!!
        assertEquals("Alum Rock", point.name)
        assertEquals(37.358135, point.latitude, 0.000001)
        assertTrue(catalog.notice.contains("SFMTA"))
        assertNull(catalog.point("JP:1114117"))
        assertNull(catalog.stationCode(65535, 65535))
        assertEquals("Zone 3", catalog.stationName(6, 3, false))
    }
}
