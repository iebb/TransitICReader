package ad.neko.cardbal.android.data

import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CardFacePickerTest {
    private fun design(id: String, bundledAsset: String? = null) = RemoteFaceManifest.Design(
        id = id, bundledAsset = bundledAsset, file = "$id.png", sha256 = "aa", bytes = 1,
    )

    private fun face(
        id: String,
        match: RemoteFaceManifest.Match = RemoteFaceManifest.Match(),
        city: Map<String, String>? = null,
        designs: List<RemoteFaceManifest.Design> = listOf(design("default")),
    ) = RemoteFaceManifest.Card(id = id, match = match, city = city, designs = designs)

    private val manifest = RemoteFaceManifest(
        schemaVersion = 2,
        cards = listOf(
            face("jp/suica", match = RemoteFaceManifest.Match(families = listOf("suica")),
                designs = listOf(design("default", bundledAsset = "suica"))),
            face("cn/city-peer", match = RemoteFaceManifest.Match(cityUnionCodes = listOf("2000")),
                designs = listOf(design("blue"), design("default"))),
            face("cn/6900", match = RemoteFaceManifest.Match(cityCodes = listOf("6900"))),
            face("cn/2900",
                match = RemoteFaceManifest.Match(cityCodes = listOf("2900"), cityUnionCodes = listOf("2000")),
                city = mapOf("en" to "Shanghai", "zh" to "Shanghai city"),
                designs = listOf(design("default"), design("no-text"), design("commemorative"))),
            face("kr/tmoney", match = RemoteFaceManifest.Match(families = listOf("t-money")),
                designs = listOf(design("default", bundledAsset = "tmoney"), design("logo"))),
        ),
    )

    private fun card(
        family: String = "China T-Union",
        face: String? = null,
        usingImage: Boolean? = null,
        applications: List<TransitApplication>? = null,
    ) = SavedCardRecord(
        id = "test",
        cardFamily = family,
        technology = "ISO7816",
        identifierLabel = "UID",
        rawIdentifierValue = "01020304",
        identifierValue = "01020304",
        scannedAt = Instant.fromEpochSeconds(0),
        color = SavedCardColor.Black,
        faceImageFileName = face,
        isUsingImage = usingImage,
        applications = applications,
    )

    private fun shanghai(face: String? = null, usingImage: Boolean? = null) = card(
        face = face, usingImage = usingImage,
        applications = listOf(
            TransitApplication(
                technology = "ISO7816",
                cardFamily = "China T-Union",
                identifier = "01020304",
                selectedAID = "A000000632010105",
                cityCode = "2900",
                scannedAt = Instant.fromEpochSeconds(0),
            ),
        ),
    )

    private val shanghaiTokens = listOf("default", "no-text", "commemorative")
        .map { RemoteFaceManifest.token("cn/2900", it) }
    private val peerTokens = listOf("blue", "default").map { RemoteFaceManifest.token("cn/city-peer", it) }

    @Test fun sheetSeparatesPhotosAndPresetsWithoutLosingSelectionOrMatchingOrder() {
        val sections = manifest.pickerSectionsFor(
            shanghai(face = "custom.jpg"), savedFaces = listOf("from-ios.png", "custom.jpg", "suica"),
        )
        assertEquals(shanghaiTokens + peerTokens, sections.matching.map { it.fileName })
        assertTrue(sections.otherPresets.none { it.fileName in shanghaiTokens + peerTokens })
        assertTrue(sections.matching.none { it.selected })
        assertEquals(setOf("custom.jpg", "from-ios.png"), sections.photos.map { it.fileName }.toSet())
        assertEquals("custom.jpg", sections.photos.single { it.selected }.fileName)
        assertTrue(sections.otherPresets.any { it.fileName == "remote.jp.suica.default.png" })
        assertFalse(sections.color.selected)
    }

    @Test fun colorModeRetainsSavedPhotosAndUnlistedPublishedPresetsInTheirTabs() {
        val sections = RemoteFaceManifest(2).pickerSectionsFor(
            shanghai(face = "remote.kr.tmoney.logo.png", usingImage = false), savedFaces = listOf("old.jpg"),
        )
        assertTrue(sections.color.selected)
        assertTrue(sections.matching.isEmpty())
        assertEquals("remote.kr.tmoney.logo.png", sections.otherPresets.single().fileName)
        assertEquals("old.jpg", sections.photos.single().fileName)
        assertTrue((sections.photos + sections.otherPresets).none { it.selected })
    }

    @Test fun cityPresetsAndPeersPrecedeCurrentUnrelatedArtwork() {
        val choices = manifest.pickerChoicesFor(shanghai(face = "suica"))
        assertNull(choices.first().fileName)
        assertEquals(shanghaiTokens + peerTokens, choices.drop(1).take(5).map { it.fileName })
        assertEquals("remote.jp.suica.default.png", choices[6].fileName)
        assertEquals("remote.jp.suica.default.png", choices.single { it.selected }.fileName)
        assertEquals(listOf("cn/6900", "kr/tmoney", "kr/tmoney"), choices.drop(7).map { it.entry?.card?.id })
        assertEquals(choices.size, choices.map { it.fileName }.toSet().size)
    }

    @Test fun familyMatchKeepsAllVariantsTogetherInManifestOrder() {
        val choices = manifest.pickerChoicesFor(card(family = "T-money", face = "suica"))
        assertEquals(
            listOf("remote.kr.tmoney.default.png", "remote.kr.tmoney.logo.png", "remote.jp.suica.default.png"),
            choices.drop(1).take(3).map { it.fileName },
        )
        assertEquals("remote.jp.suica.default.png", choices.single { it.selected }.fileName)
    }

    @Test fun applicationFamilyCanMatchWithoutLegacyTopLevelBrand() {
        val application = TransitApplication(
            technology = "FeliCa", cardFamily = "T-money", identifier = "01020304",
            scannedAt = Instant.fromEpochSeconds(0),
        )
        val choices = manifest.pickerChoicesFor(card(family = "Transit IC", applications = listOf(application)))
        assertEquals("kr/tmoney", choices[1].entry?.card?.id)
        assertEquals("remote.kr.tmoney.default.png", choices.single { it.selected }.fileName)
    }

    @Test fun unknownPhysicalTypeDoesNotDeriveRelevanceFromSelectedFaceOrTitle() {
        val unknown = card(family = "Octopus", face = "tmoney").copy(customTitle = "Shanghai Suica")
        assertTrue(manifest.relevantEntriesFor(unknown.remoteFaceMatchInput()).isEmpty())
        val choices = manifest.pickerChoicesFor(unknown)
        val current = "remote.kr.tmoney.default.png"
        assertEquals(current, choices[1].fileName)
        assertEquals(
            manifest.entries.map { it.token }.filterNot { it == current },
            choices.drop(2).map { it.fileName },
        )
        assertEquals(current, choices.single { it.selected }.fileName)
    }

    @Test fun unknownCardWithoutArtworkSelectsColorAndKeepsManifestOrder() {
        val choices = manifest.pickerChoicesFor(card(family = "Unknown"))
        assertTrue(choices.first().selected)
        assertEquals(1, choices.count { it.selected })
        assertEquals(manifest.entries.map { it.token }, choices.drop(1).map { it.fileName })
    }

    @Test fun savedPhotoFollowsAllRelevantPresetsAndStaysSelected() {
        val choices = manifest.pickerChoicesFor(shanghai(face = "custom-photo.jpg"))
        assertEquals(shanghaiTokens + peerTokens, choices.drop(1).take(5).map { it.fileName })
        assertEquals("custom-photo.jpg", choices[6].fileName)
        assertEquals("custom-photo.jpg", choices.single { it.selected }.fileName)
        assertNull(choices[6].entry)
    }

    @Test fun explicitColorChoiceRetainsPhotoButDoesNotSelectIt() {
        val original = shanghai(face = "custom-photo.jpg")
        val color = original.withFaceChoice(null)
        assertEquals(original.copy(isUsingImage = false), color)
        val choices = manifest.pickerChoicesFor(color)
        assertTrue(choices.first().selected)
        assertEquals(1, choices.count { it.selected })
        assertEquals("custom-photo.jpg", choices[6].fileName)
        assertFalse(choices[6].selected)
        assertEquals(original.copy(isUsingImage = true), color.withFaceChoice("custom-photo.jpg"))
    }

    @Test fun explicitColorChoiceWithoutSavedArtworkDoesNotSelectMatchedDefault() {
        val choices = manifest.pickerChoicesFor(shanghai(usingImage = false))
        assertTrue(choices.first().selected)
        assertEquals(1, choices.count { it.selected })
        assertEquals(shanghaiTokens + peerTokens, choices.drop(1).take(5).map { it.fileName })
    }

    @Test fun savedPhotosRemainAvailableAfterSelectingPresetAndReopening() {
        val selected = shanghai(face = "photo.jpg").withFaceChoice("remote.kr.tmoney.logo.png")
        val json = RemoteFaceManifest.json
        val reopened = json.decodeFromString<SavedCardRecord>(json.encodeToString(selected))
        val choices = manifest.pickerChoicesFor(reopened, savedFaces = listOf("photo.jpg", "another-photo.png"))
        assertEquals(
            listOf("remote.kr.tmoney.logo.png", "photo.jpg", "another-photo.png"),
            choices.drop(6).take(3).map { it.fileName },
        )
        assertEquals("remote.kr.tmoney.logo.png", choices.single { it.selected }.fileName)
        assertEquals(shanghaiTokens + peerTokens, choices.drop(1).take(5).map { it.fileName })
        assertEquals("photo.jpg", reopened.withFaceChoice("photo.jpg").faceImageFileName)
    }

    @Test fun savedPhotoListDoesNotDuplicateCurrentPhotoOrPresets() {
        val choices = manifest.pickerChoicesFor(
            shanghai(face = "photo.jpg"),
            savedFaces = listOf("photo.jpg", "suica", "", "photo.jpg"),
        )
        assertEquals(1, choices.count { it.fileName == "photo.jpg" })
        assertEquals(1, choices.count { it.fileName == "remote.jp.suica.default.png" })
        assertEquals(1, choices.count { it.selected })
        assertEquals("photo.jpg", choices.single { it.selected }.fileName)
    }

    @Test fun savedPresetChoiceSurvivesBackupSerializationAndColorToggle() {
        val choice = shanghai(face = "photo.jpg").withFaceChoice("remote.cn.2900.no-text.png")
        val json = RemoteFaceManifest.json
        val restored = json.decodeFromString<SavedCardRecord>(json.encodeToString(choice))
        assertEquals(choice, restored)
        assertEquals("remote.cn.2900.no-text.png", manifest.pickerChoicesFor(restored).single { it.selected }.fileName)
        val disabled = restored.withFaceChoice(null)
        assertFalse(disabled.finalIsUsingImage)
        assertEquals("remote.cn.2900.no-text.png", disabled.faceImageFileName)
    }

    @Test fun cityPeersMatchCodesOrAnyLocalizedCityValueWithinTheSameRegion() {
        val exact = manifest.cards.first { it.id == "cn/2900" }
        val peers = listOf(
            face("cn/by-code", match = RemoteFaceManifest.Match(cityCodes = listOf("2900"))),
            face("cn/by-union-code", match = RemoteFaceManifest.Match(cityUnionCodes = listOf("2000"))),
            face("cn/by-name", city = mapOf("ja" to " SHANGHAI ")),
        )
        val unrelated = listOf(
            face("jp/same-name", city = mapOf("en" to "Shanghai")),
            face("cn/no-city", city = emptyMap()),
            face("cn/empty-city", city = mapOf("en" to "")),
            face("unknown/same-name", city = mapOf("en" to "Shanghai")),
        )
        // Family selects the exact card even when a city peer is earlier in the manifest.
        val exactByFamily = exact.copy(match = exact.match.copy(families = listOf("shanghai")))
        val catalog = manifest.copy(cards = unrelated + peers + exactByFamily)
        assertEquals(
            listOf(exact.id, exact.id, exact.id) + peers.map { it.id },
            catalog.relevantEntriesFor(RemoteFaceMatchInput(family = "Shanghai")).map { it.card.id },
        )
    }

    @Test fun emptyCityValuesDoNotMakeUnknownCardsRelated() {
        val exact = face("cn/exact", city = mapOf("en" to ""),
            match = RemoteFaceManifest.Match(cityCodes = listOf(""), cityUnionCodes = listOf(""), families = listOf("exact")))
        val unknown = face("cn/unknown", city = mapOf("en" to ""),
            match = RemoteFaceManifest.Match(cityCodes = listOf(""), cityUnionCodes = listOf("")))
        val catalog = manifest.copy(cards = listOf(unknown, exact))
        assertEquals(
            listOf("cn/exact"),
            catalog.relevantEntriesFor(RemoteFaceMatchInput(family = "exact")).map { it.card.id },
        )
        assertTrue(catalog.relevantEntriesFor(RemoteFaceMatchInput(tUnionCityCodes = listOf(""), family = "unknown")).isEmpty())
    }

    @Test fun legacyCityFieldIsUsedOnlyWhenApplicationCityIsAbsent() {
        val legacy = card().copy(
            selectedAID = "A000000632010105",
            resultFields = listOf(SavedCardField("City Code", "2900")),
        )
        assertEquals("cn/2900", manifest.match(legacy.remoteFaceMatchInput())?.id)
        val physical = shanghai().copy(resultFields = listOf(SavedCardField("City Code", "6900")))
        assertEquals("cn/2900", manifest.match(physical.remoteFaceMatchInput())?.id)
    }

    @Test fun emptyManifestKeepsSavedPhotoAndExplicitColorChoiceUsable() {
        val empty = manifest.copy(cards = emptyList())
        val photo = shanghai(face = "photo.jpg", usingImage = false)
        val choices = empty.pickerChoicesFor(photo)
        assertEquals(listOf(null, "photo.jpg"), choices.map { it.fileName })
        assertTrue(choices.first().selected)
        assertEquals("photo.jpg", empty.pickerChoicesFor(photo.withFaceChoice("photo.jpg")).single { it.selected }.fileName)
    }
}
