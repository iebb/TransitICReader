package ad.neko.cardbal.android.data

import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteCardFacesTest {
    private val manifest = RemoteFaceManifest.parse(
        """
        {"schemaVersion": 2, "cards": [
          {"id": "cn/2900", "region": "CN", "name": {"zh": "上海公共交通卡", "en": "Shanghai Public Transportation Card"},
           "city": {"zh": "上海", "en": "Shanghai"},
           "match": {"cityCodes": ["2900"], "cityUnionCodes": ["2000"], "cardPrefixes": ["31047700"], "families": [], "serialPrefixes": []},
           "designs": [{"id": "default", "file": "faces/cn/2900/default.png", "sha256": "aa", "bytes": 1, "width": 1200, "height": 760, "colors": 19}]},
          {"id": "cn/6900", "region": "CN", "name": {"zh": "宜居畅通卡", "en": "Chongqing Changtong Card"},
           "match": {"cityCodes": ["6900"], "cardPrefixes": ["31049200", "31049201"]},
           "designs": [{"id": "default", "file": "faces/cn/6900/default.png", "sha256": "bb", "bytes": 1}]},
          {"id": "jp/suica", "region": "JP", "name": {"en": "Suica"},
           "match": {"families": ["suica"], "serialPrefixes": ["JE"]},
           "designs": [{"id": "default", "bundledAsset": "suica", "file": "faces/jp/suica/default.png", "sha256": "cc", "bytes": 1}]},
          {"id": "jp/okica", "region": "JP", "name": {"en": "OKICA"},
           "match": {"families": ["okica"]},
           "designs": [{"id": "default", "bundledAsset": "okica", "file": "faces/jp/okica/default.png", "sha256": "dd", "bytes": 1}]},
          {"id": "kr/ezl", "region": "KR", "name": {"en": "EZL / Cashbee"},
           "match": {"families": ["ezl", "cashbee"]},
           "designs": [{"id": "default", "bundledAsset": "ezl", "file": "faces/kr/ezl/default.png", "sha256": "ee", "bytes": 1}]},
          {"id": "sg/ezlink", "region": "SG", "name": {"en": "EZ-Link"},
           "match": {"families": ["ez-link", "ezlink"]},
           "designs": [{"id": "default", "bundledAsset": "ezlink", "file": "faces/sg/ezlink/default.png", "sha256": "ff", "bytes": 1}]},
          {"id": "kr/tmoney", "region": "KR", "name": {"en": "T-money"},
           "match": {"families": ["t-money", "tmoney"]},
           "designs": [
             {"id": "default", "bundledAsset": "tmoney", "file": "faces/kr/tmoney/default.png", "sha256": "11", "bytes": 1},
             {"id": "logo", "name": {"en": "T-money (logo)"}, "file": "faces/kr/tmoney/logo.png", "sha256": "22", "bytes": 1}]}
        ]}
        """.trimIndent(),
    )!!

    private fun card(
        family: String,
        serial: String? = null,
        face: String? = null,
        usingImage: Boolean? = null,
        applications: List<TransitApplication>? = null,
    ) = SavedCardRecord(
        id = "card",
        cardFamily = family,
        technology = "ISO7816",
        identifierLabel = "UID",
        rawIdentifierValue = "01020304",
        identifierValue = "01020304",
        realSerialNumber = serial,
        applications = applications,
        scannedAt = Instant.fromEpochSeconds(0),
        color = SavedCardColor.Black,
        faceImageFileName = face,
        isUsingImage = usingImage,
    )

    private fun application(aid: String, cityCode: String) = TransitApplication(
        technology = "ISO7816",
        cardFamily = "China T-Union",
        identifier = "01020304",
        selectedAID = aid,
        cityCode = cityCode,
        scannedAt = Instant.fromEpochSeconds(0),
    )

    @Test
    fun tokensFollowCardAndDesignIds() {
        assertEquals("remote.cn.2900.default.png", RemoteFaceManifest.token("cn/2900", "default"))
        assertEquals("remote.kr.tmoney.logo.png", RemoteFaceManifest.token("kr/tmoney", "logo"))
        assertTrue(RemoteFaceManifest.isToken("remote.fr.la-carte.blue.png"))
        assertFalse(RemoteFaceManifest.isToken("remote.png"))
        assertFalse(RemoteFaceManifest.isToken("remote.../etc/passwd.png"))
        assertFalse(RemoteFaceManifest.isToken("2C7B0E3A.jpg"))
    }

    @Test
    fun rejectsOtherSchemaVersions() {
        assertNull(RemoteFaceManifest.parse("""{"schemaVersion": 1, "faces": []}"""))
        assertNull(RemoteFaceManifest.parse("not json"))
    }

    @Test
    fun tUnionCityCodeWinsOverCardPrefix() {
        val shanghai = card("China T-Union", serial = "31049201000012345",
            applications = listOf(application("A000000632010105", "2900")))
        assertEquals("cn/2900", manifest.match(shanghai.remoteFaceMatchInput())?.id)
    }

    @Test
    fun cityUnionCodeMatchesLegacyShanghaiCards() {
        val legacy = card("City Union", applications = listOf(application("A00000000386980701", "2000")))
        assertEquals("cn/2900", manifest.match(legacy.remoteFaceMatchInput())?.id)
    }

    @Test
    fun cardPrefixIgnoresSpacing() {
        assertEquals("cn/6900", manifest.match(RemoteFaceMatchInput(serialNumbers = listOf("3104 9201 0000 1234")))?.id)
        assertEquals("cn/2900", manifest.match(RemoteFaceMatchInput(serialNumbers = listOf("31047700 00001234")))?.id)
    }

    @Test
    fun longestFamilyWinsSoEzLinkIsNotEzl() {
        assertEquals("sg/ezlink", manifest.match(RemoteFaceMatchInput(family = "EZLink"))?.id)
        assertEquals("sg/ezlink", manifest.match(RemoteFaceMatchInput(family = "EZ-Link"))?.id)
        assertEquals("kr/ezl", manifest.match(RemoteFaceMatchInput(family = "EZL / Cashbee"))?.id)
    }

    @Test
    fun serialPrefixMatchesJapaneseCards() {
        assertEquals("jp/suica", manifest.match(RemoteFaceMatchInput(family = "Transit IC", serialNumbers = listOf("JE 123 4567")))?.id)
        assertNull(manifest.match(RemoteFaceMatchInput(family = "Octopus")))
    }

    @Test
    fun faceTokenUsesMatchedDefaultForUntouchedCards() {
        val shanghai = card("China T-Union", applications = listOf(application("A000000632010105", "2900")))
        assertEquals("remote.cn.2900.default.png", manifest.faceTokenFor(shanghai))
        assertEquals("remote.jp.okica.default.png", manifest.faceTokenFor(card("OKICA")))
    }

    @Test
    fun faceTokenRespectsTheCardsChoice() {
        assertEquals("remote.kr.tmoney.logo.png", manifest.faceTokenFor(card("T-money", face = "remote.kr.tmoney.logo.png")))
        // iPhone backups name bundled presets, which Android may not ship.
        assertEquals("remote.jp.okica.default.png", manifest.faceTokenFor(card("OKICA", face = "okica")))
        assertEquals("remote.sg.ezlink.default.png", manifest.faceTokenFor(card("EZ-Link", face = "ezlink")))
        assertNull(manifest.faceTokenFor(card("OKICA", face = "3F2A.jpg")))
        assertNull(manifest.faceTokenFor(card("OKICA", face = "okica", usingImage = false)))
        assertNull(manifest.faceTokenFor(card("OKICA", usingImage = false)))
    }

    @Test
    fun entriesCoverEveryDesign() {
        val tokens = manifest.entries.map { it.token }
        assertEquals(8, tokens.size)
        assertNotNull(manifest.entry("remote.kr.tmoney.logo.png"))
        assertNull(manifest.entry("remote.kr.tmoney.missing.png"))
    }

    @Test
    fun sha256IsLowercaseHex() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            RemoteCardFaces.sha256("abc".toByteArray()),
        )
    }
}
