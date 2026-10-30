package ad.neko.cardbal.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class LocalizationTest {
    private fun translate(text: String, entries: Map<String, String>) =
        PresentationStrings.translate(text, entries.keys, entries::get)

    @Test fun localizesStoredLabelsAndInterpolatedMessages() {
        val entries = mapOf(
            "Import failed: %@" to "导入失败：%@",
            "This file is not a Trip Reader backup." to "此文件不是读卡识途备份。",
            "Imported %lld cards (%lld replaced)" to "已导入 %1\$lld 张卡片（替换 %2\$lld 张）",
            "Balance" to "余额",
        )
        assertEquals("导入失败：此文件不是读卡识途备份。", translate("Import failed: This file is not a Trip Reader backup.", entries))
        assertEquals("已导入 2 张卡片（替换 1 张）", translate("Imported 2 cards (1 replaced)", entries))
        assertEquals("余额 (IDR)", translate("Balance (IDR)", entries))
    }

    @Test fun supportsReorderedArgumentsAndLanguageChanges() {
        assertEquals("2 → 1", translate("From 1 to 2", mapOf("From %lld to %lld" to "%2\$lld → %1\$lld")))
        assertEquals("読み取り中", translate("Reading", mapOf("Reading" to "読み取り中")))
        assertEquals("읽는 중", translate("Reading", mapOf("Reading" to "읽는 중")))
    }

    @Test fun preservesUnknownContentAndLiteralReplacementCharacters() {
        val entries = mapOf("Import failed: %@" to "失败：%@")
        assertEquals("A000000632010105", translate("A000000632010105", entries))
        assertEquals("失败：\$1\\path", translate("Import failed: \$1\\path", entries))
        assertEquals("My commuter card", translate("My commuter card", entries))
    }
}
