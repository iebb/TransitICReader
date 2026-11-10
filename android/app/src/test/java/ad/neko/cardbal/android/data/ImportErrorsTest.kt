package ad.neko.cardbal.android.data

import java.io.IOException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportErrorsTest {
    @Test
    fun samsungMediaProviderRefusalIsAnAccessProblem() {
        val refusal = SecurityException("com.samsung.android.providers.media has no access to content://media/external_primary/file/1000001204")
        assertTrue(ImportErrors.isFileAccessDenied(refusal))
        assertTrue(ImportErrors.isFileAccessDenied(IllegalStateException("wrapped", refusal)))
    }

    @Test
    fun otherFailuresKeepTheirOwnMessage() {
        assertFalse(ImportErrors.isFileAccessDenied(IOException("Unable to open selected backup")))
        assertFalse(ImportErrors.isFileAccessDenied(IllegalArgumentException("Not a CardBal backup")))
    }
}
