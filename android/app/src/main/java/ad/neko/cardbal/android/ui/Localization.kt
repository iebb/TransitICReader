package ad.neko.cardbal.android.ui

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import ad.neko.cardbal.android.data.SavedCardRecord

/** Only pass app-owned text here; card identifiers and user titles stay verbatim. */
@Composable
fun tr(text: String): String {
    LocalConfiguration.current
    return LocalContext.current.tr(text)
}

fun Context.tr(text: String): String =
    PresentationStrings.translate(text, localizedResources.keys) { key -> localizedResources[key]?.let(::getString) }

@Composable
fun cardTitle(card: SavedCardRecord): String =
    LocalContext.current.cardTitle(card)

fun Context.cardTitle(card: SavedCardRecord): String =
    if (!card.customTitle.isNullOrBlank()) card.displayTitle else tr(card.displayTitle)

/** Matches canonical labels saved by decoders without changing persisted data. */
internal object PresentationStrings {
    private val placeholder = Regex("%(?:(\\d+)\\$)?[-+0 #]*\\d*(?:\\.\\d+)?(?:ll|l)?([@diuoxXfFeEgGs])")
    private data class Pattern(val key: String, val regex: Regex)
    private var cachedKeys: Set<String>? = null
    private var patterns: List<Pattern> = emptyList()

    @Synchronized
    private fun patterns(keys: Set<String>): List<Pattern> {
        if (keys === cachedKeys) return patterns
        patterns = keys.mapNotNull { key ->
            val tokens = placeholder.findAll(key).toList()
            if (tokens.isEmpty() || !Regex("[A-Za-z]{2}").containsMatchIn(placeholder.replace(key, ""))) return@mapNotNull null
            var offset = 0
            val expression = buildString {
                append("^")
                for (token in tokens) {
                    append(Regex.escape(key.substring(offset, token.range.first)))
                    append(if (token.groupValues[2] in listOf("@", "s")) "(.+?)" else "([-+0-9A-Fa-f.,]+)")
                    offset = token.range.last + 1
                }
                append(Regex.escape(key.substring(offset)))
                append("$")
            }
            Pattern(key, Regex(expression, RegexOption.DOT_MATCHES_ALL))
        }.sortedByDescending { it.key.length }
        cachedKeys = keys
        return patterns
    }

    fun translate(text: String, keys: Set<String>, lookup: (String) -> String?): String =
        translate(text, patterns(keys), lookup, 0)

    private fun translate(text: String, patterns: List<Pattern>, lookup: (String) -> String?, depth: Int): String {
        if (text.isEmpty() || depth >= 5) return text
        lookup(text)?.let { return it }
        for (pattern in patterns) {
            val match = pattern.regex.matchEntire(text) ?: continue
            val template = lookup(pattern.key) ?: continue
            val arguments = match.groupValues.drop(1).map { translate(it, patterns, lookup, depth + 1) }
            var index = 0
            return placeholder.replace(template) { token ->
                val position = token.groupValues[1].toIntOrNull()?.minus(1) ?: index
                index += 1
                arguments.getOrNull(position) ?: token.value
            }
        }
        val open = text.indexOf(" (")
        if (open >= 0 && text.endsWith(")")) {
            val prefix = text.substring(0, open)
            val translated = translate(prefix, patterns, lookup, depth + 1)
            if (prefix != translated) return translated + text.substring(open)
        }
        for (separator in listOf("\n", " · ", ": ", " / ", " + ", " → ", " -> ")) {
            if (separator in text) return text.split(separator).joinToString(separator) { translate(it, patterns, lookup, depth + 1) }
        }
        return text
    }
}
