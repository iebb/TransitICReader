package ad.neko.cardbal.android.ui

import android.content.Intent
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.pressBack
import androidx.test.platform.app.InstrumentationRegistry
import ad.neko.cardbal.android.MainActivity
import ad.neko.cardbal.android.data.CardBackupData
import ad.neko.cardbal.android.data.SavedCardColor
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.TransitTransaction
import java.io.File
import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

private fun testCard(index: Int? = null) = SavedCardRecord(
    id = "sample:ui:card${index?.let { ":$it" }.orEmpty()}",
    cardFamily = "UI test card",
    customTitle = "UI test card${index?.let { " $it" }.orEmpty()}",
    technology = "FeliCa",
    identifierLabel = "IDm",
    rawIdentifierValue = "01020304050607%02X".format(index ?: 8),
    identifierValue = "01020304050607%02X".format(index ?: 8),
    scannedAt = Instant.parse("2026-01-01T00:00:00Z"),
    color = SavedCardColor.Black,
)

class CardDetailGestureTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private fun text(key: String) = compose.activity.tr(key)
    private var renamedTo: String? = null
    private var deleted = false

    private fun showDetails() {
        val transactions = List(60) { index ->
            TransitTransaction(
                type = "Transaction",
                location = "UI test record $index",
                recordNumber = index,
                rawData = "%032X".format(index),
            )
        }
        compose.setContent {
            CardBalTheme {
                var showingDetails by remember { mutableStateOf(true) }
                if (showingDetails) {
                    CardDetailScreen(
                        card = testCard(),
                        transactions = transactions,
                        routePoints = emptyList(),
                        routes = emptyList(),
                        rawExplanationFor = { null },
                        onBack = { showingDetails = false },
                        onCustomize = { change -> renamedTo = change(testCard()).customTitle },
                        onDelete = { deleted = true },
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Text("Parent page")
                }
            }
        }
    }

    private fun scrollToTransactions() {
        compose.onNode(hasScrollAction())
            .performScrollToNode(hasText("UI test record 20"))
    }

    private fun scrollPosition(): Float = compose.onNode(hasScrollAction())
        .fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()

    @Test
    fun swipeUpOnTransactionsScrollsWithoutOpeningRawRecord() {
        showDetails()
        scrollToTransactions()
        val before = scrollPosition()

        compose.onNode(hasScrollAction()).performTouchInput { swipeUp() }

        compose.onNodeWithText(text("Highlighted Hex")).assertDoesNotExist()
        assertTrue("An upward finger drag must advance the list", scrollPosition() > before)
    }

    @Test
    fun swipeDownOnTransactionsScrollsWithoutOpeningRawRecord() {
        showDetails()
        scrollToTransactions()
        val before = scrollPosition()

        compose.onNode(hasScrollAction()).performTouchInput { swipeDown() }

        compose.onNodeWithText(text("Highlighted Hex")).assertDoesNotExist()
        assertTrue("A downward finger drag must move toward earlier rows", scrollPosition() < before)
    }

    @Test
    fun tappingTransactionOpensRawRecordAndBackStaysInCardDetails() {
        showDetails()
        scrollToTransactions()
        compose.onNodeWithText("UI test record 20").performClick()
        compose.onNodeWithText(text("Highlighted Hex")).assertIsDisplayed()

        pressBack()
        compose.waitForIdle()
        // An expanded Material sheet may first return to its partial state.
        if (compose.onAllNodes(hasText(text("Highlighted Hex"))).fetchSemanticsNodes().isNotEmpty()) {
            pressBack()
        }

        compose.onNodeWithText(text("Highlighted Hex")).assertDoesNotExist()
        compose.onNodeWithText("Parent page").assertDoesNotExist()
        compose.onNodeWithContentDescription(text("Back")).assertIsDisplayed()
        assertFalse(compose.activity.isFinishing)

        pressBack()
        compose.onNodeWithText("Parent page").assertIsDisplayed()
        assertFalse(compose.activity.isFinishing)
    }

    @Test
    fun systemBackFromCardDetailsReturnsToParent() {
        showDetails()

        pressBack()

        compose.onNodeWithText("Parent page").assertIsDisplayed()
        assertFalse(compose.activity.isFinishing)
    }

    @Test
    fun customizeCardSavesTheEnteredName() {
        showDetails()
        compose.onNodeWithText(text("Customize Card")).performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("UI test card") and hasSetTextAction())
        compose.onNode(hasText("UI test card") and hasSetTextAction()).performTextReplacement("Commuter")

        compose.waitUntil(timeoutMillis = 3_000) { renamedTo == "Commuter" }
        assertEquals("Commuter", renamedTo)
    }

    @Test
    fun deleteAsksForConfirmationFirst() {
        showDetails()
        compose.onNodeWithContentDescription(text("Delete Card")).performClick()
        compose.onNodeWithText(text("Cancel")).performClick()
        assertFalse(deleted)

        compose.onNodeWithContentDescription(text("Delete Card")).performClick()
        compose.onNodeWithText(text("Delete")).performClick()
        assertTrue(deleted)
    }

    @Test
    fun backFromCardFacePickerStaysInCardDetails() {
        showDetails()
        compose.onNodeWithText(text("Customize Card")).performClick()
        compose.onNode(hasText(text("Card Face")) and hasClickAction()).performClick()
        compose.onNodeWithText(text("Presets")).assertIsDisplayed()

        pressBack()

        compose.onNodeWithText(text("Presets")).assertDoesNotExist()
        compose.onNodeWithText(text("Customize Card")).assertIsDisplayed()

        pressBack()

        compose.onNodeWithContentDescription(text("Back")).assertIsDisplayed()
        compose.onNodeWithText(text("Customize Card")).assertIsDisplayed()
        compose.onNodeWithText("Parent page").assertDoesNotExist()
    }

    @Test
    fun backFromStationReportStaysInCardDetails() {
        showDetails()
        compose.onNode(hasScrollAction())
            .performScrollToNode(hasText(text("Report or Correct a Station")))
        compose.onNodeWithText(text("Report or Correct a Station")).performClick()
        compose.onNodeWithText(text("Report Station")).assertIsDisplayed()

        pressBack()

        compose.onNodeWithText(text("Report Station")).assertDoesNotExist()
        compose.onNodeWithContentDescription(text("Back")).assertIsDisplayed()
        compose.onNodeWithText("Parent page").assertDoesNotExist()
        pressBack()
        compose.onNodeWithText("Parent page").assertIsDisplayed()
    }
}

class AppBackNavigationTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val sampleFile = File(context.filesDir, "development/sample-wallet.json")
    private var previousSamples: ByteArray? = null
    private var scenario: ActivityScenario<MainActivity>? = null

    private fun text(key: String) = context.tr(key)

    private fun tab(name: String) = compose.onNode(hasText(text(name)) and isSelectable())

    @Before
    fun launchSampleWallet() {
        assumeTrue("Sample-wallet navigation tests require an emulator", Build.HARDWARE in setOf("goldfish", "ranchu"))
        previousSamples = sampleFile.takeIf { it.isFile }?.readBytes()
        sampleFile.parentFile!!.mkdirs()
        sampleFile.writeText(Json.encodeToString(CardBackupData(cards = listOf(testCard()))))
        scenario = ActivityScenario.launch(
            Intent(context, MainActivity::class.java)
                .putExtra("cardbal.developmentSamples", true),
        )
    }

    @After
    fun closeSampleWallet() {
        scenario?.close()
        if (scenario != null) {
            previousSamples?.let(sampleFile::writeBytes) ?: sampleFile.delete()
        }
    }

    @Test
    fun backFromEachTopLevelTabReturnsToScan() {
        for (name in listOf("Cards", "Map", "Settings")) {
            tab(name).performClick()
            tab(name).assertIsSelected()

            pressBack()

            tab("Scan").assertIsSelected()
            scenario!!.onActivity { assertFalse(it.isFinishing) }
        }
    }

    @Test
    fun backCollapsesWalletPreviewBeforeLeavingCards() {
        tab("Cards").performClick()
        compose.onNodeWithText("UI test card").performClick()
        compose.onNodeWithText(text("Details")).assertIsDisplayed()

        pressBack()

        compose.onNodeWithText(text("Details")).assertDoesNotExist()
        tab("Cards").assertIsSelected()
        pressBack()
        tab("Scan").assertIsSelected()
    }

    @Test
    fun cardDetailsReturnToTheirSourceTab() {
        tab("Cards").performClick()
        compose.onNodeWithText("UI test card").performClick()
        compose.onNodeWithText(text("Details")).performClick()
        compose.onNodeWithContentDescription(text("Back")).assertIsDisplayed()

        pressBack()

        tab("Cards").assertIsSelected()
        scenario!!.onActivity { assertFalse(it.isFinishing) }
    }

    @Test
    fun backCollapsesMapPanelBeforeLeavingMap() {
        tab("Map").performClick()
        compose.onNodeWithText(text("Routes")).performClick()
        compose.onNodeWithText(text("Visible routes")).assertIsDisplayed()

        pressBack()

        compose.onNodeWithText(text("Visible routes")).assertDoesNotExist()
        tab("Map").assertIsSelected()
        pressBack()
        tab("Scan").assertIsSelected()
    }
}

class WalletStackLayoutTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val sampleFile = File(context.filesDir, "development/sample-wallet.json")
    private var previousSamples: ByteArray? = null
    private var scenario: ActivityScenario<MainActivity>? = null

    private fun text(key: String) = context.tr(key)

    @Before
    fun launchLargeSampleWallet() {
        assumeTrue("Sample-wallet layout tests require an emulator", Build.HARDWARE in setOf("goldfish", "ranchu"))
        previousSamples = sampleFile.takeIf { it.isFile }?.readBytes()
        sampleFile.parentFile!!.mkdirs()
        sampleFile.writeText(Json.encodeToString(CardBackupData(cards = (1..8).map(::testCard))))
        scenario = ActivityScenario.launch(
            Intent(context, MainActivity::class.java)
                .putExtra("cardbal.developmentSamples", true),
        )
    }

    @After
    fun closeSampleWallet() {
        scenario?.close()
        if (scenario != null) {
            previousSamples?.let(sampleFile::writeBytes) ?: sampleFile.delete()
        }
    }

    @Test
    fun detailsSitBetweenSelectedCardAndStackWithoutScrolling() {
        compose.onNode(hasText(text("Cards")) and isSelectable()).performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("UI test card 8"))
        compose.onNodeWithText("UI test card 8").performClick()

        val details = compose.onNodeWithText(text("Details"))
        details.assertIsDisplayed()
        val detailsBottom = details.getUnclippedBoundsInRoot().bottom
        val nextCardTop = compose.onNodeWithText("UI test card 1").getUnclippedBoundsInRoot().top
        assertTrue("The stack must start below the Details action", nextCardTop > detailsBottom)
    }
}
