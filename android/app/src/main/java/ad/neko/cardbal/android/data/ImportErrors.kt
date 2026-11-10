package ad.neko.cardbal.android.data

/** Explains why a backup file picked in the system file picker could not be read. */
object ImportErrors {
    /**
     * Some Samsung phones refuse to hand over a file picked from the Downloads or Recent
     * shortcuts: "com.samsung.android.providers.media has no access to content://media/…"
     * (a SecurityException from the system, issue #5). The same file opens when it is picked
     * from Internal storage › Download or moved with My Files.
     */
    const val FILE_ACCESS_DENIED =
        "Android didn't give CardBal access to this file. In the file picker, open it from Internal storage › Download instead of Downloads or Recent, or move it with My Files, then try again."

    fun isFileAccessDenied(error: Throwable): Boolean =
        generateSequence(error) { it.cause }.take(8).any { it is SecurityException }
}
