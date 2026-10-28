package ad.neko.cardbal.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ad.neko.cardbal.android.R

private val LightScheme = lightColorScheme(
    primary = Color(0xFF1F6B64),
    secondary = Color(0xFF6B5E3D),
    tertiary = Color(0xFF8B3D50),
    background = Color(0xFFFAF8F5),
    surface = Color(0xFFFFFBFE),
    surfaceVariant = Color(0xFFE7E0D8),
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFF79D0C6),
    secondary = Color(0xFFD7C58F),
    tertiary = Color(0xFFFFB0C2),
    surface = Color(0xFF141917),
    surfaceVariant = Color(0xFF404944),
)

private val ExpressiveShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(18.dp),
    large = RoundedCornerShape(26.dp),
    extraLarge = RoundedCornerShape(34.dp),
)

private val ManropeFamily = FontFamily(
    Font(R.font.manrope_regular, weight = FontWeight.Normal),
    Font(R.font.manrope_medium, weight = FontWeight.Medium),
    Font(R.font.manrope_semibold, weight = FontWeight.SemiBold),
    Font(R.font.manrope_bold, weight = FontWeight.Bold),
    Font(R.font.manrope_extrabold, weight = FontWeight.ExtraBold),
)

private fun TextStyle.withAppFont(weight: FontWeight? = null): TextStyle = copy(
    fontFamily = ManropeFamily,
    fontWeight = weight ?: fontWeight,
    letterSpacing = 0.sp,
)

private val ExpressiveTypography = Typography().let { base ->
    base.copy(
        displayLarge = base.displayLarge.withAppFont(FontWeight.ExtraBold),
        displayMedium = base.displayMedium.withAppFont(FontWeight.ExtraBold),
        displaySmall = base.displaySmall.withAppFont(FontWeight.Bold),
        headlineLarge = base.headlineLarge.withAppFont(FontWeight.ExtraBold),
        headlineMedium = base.headlineMedium.withAppFont(FontWeight.Bold),
        headlineSmall = base.headlineSmall.withAppFont(FontWeight.Bold),
        titleLarge = base.titleLarge.withAppFont(FontWeight.Bold),
        titleMedium = base.titleMedium.withAppFont(FontWeight.SemiBold),
        titleSmall = base.titleSmall.withAppFont(FontWeight.SemiBold),
        bodyLarge = base.bodyLarge.withAppFont(FontWeight.Medium),
        bodyMedium = base.bodyMedium.withAppFont(FontWeight.Medium),
        bodySmall = base.bodySmall.withAppFont(FontWeight.Medium),
        labelLarge = base.labelLarge.withAppFont(FontWeight.SemiBold),
        labelMedium = base.labelMedium.withAppFont(FontWeight.SemiBold),
        labelSmall = base.labelSmall.withAppFont(FontWeight.Medium),
    )
}

@Composable
fun CardBalTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val scheme: ColorScheme = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else if (darkTheme) {
        DarkScheme
    } else {
        LightScheme
    }
    MaterialTheme(
        colorScheme = scheme,
        typography = ExpressiveTypography,
        shapes = ExpressiveShapes,
        content = content,
    )
}
