package ad.neko.cardbal.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.ConfirmationNumber
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.DirectionsBoat
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LocalCafe
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PedalBike
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.filled.Tram
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Work
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ad.neko.cardbal.android.data.DualCurrencyBalance
import ad.neko.cardbal.android.data.ImageFaceEnhancer
import ad.neko.cardbal.android.data.SavedCardRecord

enum class WalletCardMode { Hero, Compact }

@Composable
fun WalletCard(card: SavedCardRecord, modifier: Modifier = Modifier, mode: WalletCardMode = WalletCardMode.Hero) {
    val context = LocalContext.current
    val importedImage = remember(card.faceImageFileName) {
        importedFaceImageFor(context, card.faceImageFileName)
    }?.takeIf { card.finalIsUsingImage }
    val image = offlineDrawableFor(card)
    val remoteImage = rememberRemoteFace(card)
    val bitmap = importedImage ?: remoteImage
    val isPhotoFace = bitmap != null || image != null
    // Matches the iOS Shadow text contrast: a soft dark shadow under each line of text.
    val textShadow = if (isPhotoFace && card.imageFaceEnhancer == ImageFaceEnhancer.border) {
        Shadow(Color.Black.copy(alpha = 0.8f), Offset(0f, 4f), 10f)
    } else {
        null
    }
    val color = Color(
        red = card.color.red.toFloat(),
        green = card.color.green.toFloat(),
        blue = card.color.blue.toFloat(),
    )
    val titleColor = card.titleTextColorOverride?.toColor()
        ?: card.autoTitleTextColor?.toColor()
        ?: Color.White
    val balanceColor = card.balanceTextColorOverride?.toColor()
        ?: card.autoBalanceTextColor?.toColor()
        ?: Color.White
    // Set only for an Octopus – China T-Union card whose yuan balance was read with its HKD balance.
    val yuanBalance = remember(card.applications) { DualCurrencyBalance.from(card.applications)?.yuanBalance }
    val cardModifier = when (mode) {
        WalletCardMode.Hero -> modifier.fillMaxWidth().aspectRatio(27f / 17f)
        WalletCardMode.Compact -> modifier.fillMaxWidth().height(154.dp)
    }
    Card(
        modifier = cardModifier,
        shape = MaterialTheme.shapes.large,
        elevation = CardDefaults.cardElevation(defaultElevation = if (mode == WalletCardMode.Hero) 2.dp else 0.dp),
    ) {
        Box(Modifier.fillMaxSize()) {
            if (isPhotoFace) {
                val face: @Composable (Modifier) -> Unit = { faceModifier ->
                    if (bitmap != null) {
                        Image(bitmap = bitmap, contentDescription = null, modifier = faceModifier, contentScale = ContentScale.Crop)
                    } else if (image != null) {
                        Image(painter = painterResource(image), contentDescription = null, modifier = faceModifier, contentScale = ContentScale.Crop)
                    }
                }
                face(Modifier.matchParentSize())
                if (card.finalFrostedHeader) {
                    FrostedHeader(face)
                } else if (card.imageFaceEnhancer == ImageFaceEnhancer.mask) {
                    Box(
                        Modifier.matchParentSize().background(
                            Brush.verticalGradient(
                                0f to Color.Black.copy(alpha = 0.58f),
                                0.2f to Color.Black.copy(alpha = 0.34f),
                                0.38f to Color.Black.copy(alpha = 0.1f),
                                0.56f to Color.Transparent,
                                0.72f to Color.Transparent,
                                1f to Color.Black.copy(alpha = 0.22f),
                            ),
                        ),
                    )
                }
            } else {
                Box(
                    Modifier.matchParentSize().background(
                        cardBrush(card, color),
                    ),
                )
            }

            if (mode == WalletCardMode.Compact) {
                Box(Modifier.matchParentSize().padding(12.dp), contentAlignment = Alignment.TopStart) {
                    MarkerBadge(card, showsDefault = true)
                }
            } else {
                Column(
                    Modifier.matchParentSize().padding(18.dp),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                MarkerBadge(card, showsDefault = false)
                                if (!(isPhotoFace && card.finalHideTitle)) {
                                    Text(
                                        cardTitle(card),
                                        color = titleColor,
                                        style = MaterialTheme.typography.titleLarge.copy(shadow = textShadow),
                                        fontWeight = FontWeight.Bold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                            val serialNumber = card.privacyFormattedSerialNumber(DisplaySettings.serialNumberMode)
                            if (!card.finalHideSerialNumber && serialNumber.isNotEmpty()) {
                                Text(
                                    serialNumber,
                                    color = titleColor.copy(alpha = 0.82f),
                                    style = MaterialTheme.typography.bodyMedium.copy(shadow = textShadow),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }

                        if (card.visibleBalance.isNotBlank() && yuanBalance != null) {
                            // An Octopus – China T-Union card's second balance, under the HKD one.
                            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(
                                    tr(card.visibleBalance),
                                    color = balanceColor,
                                    style = MaterialTheme.typography.headlineSmall.copy(shadow = textShadow),
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    yuanBalance,
                                    color = titleColor.copy(alpha = 0.9f),
                                    style = MaterialTheme.typography.titleSmall.copy(fontSize = 15.sp, shadow = textShadow),
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.semantics { contentDescription = context.tr("CNY Balance") + ", " + yuanBalance },
                                )
                            }
                        } else if (card.visibleBalance.isNotBlank()) {
                            Text(
                                tr(card.visibleBalance),
                                color = balanceColor,
                                style = MaterialTheme.typography.headlineSmall.copy(shadow = textShadow),
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    Spacer(Modifier.height(1.dp))
                }
            }
        }
    }
}

/** The balance rows of an Octopus – China T-Union card with a reported exchange rate: both
 *  currencies and the rate. Every other card keeps its existing rows. */
@Composable
fun DualBalanceRows(balance: String, dual: DualCurrencyBalance) {
    val context = LocalContext.current
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    BalanceValueRow(tr("HKD Balance"), tr(balance))
    val yuan = dual.yuanBalance
    if (yuan != null) {
        BalanceValueRow(tr("CNY Balance"), yuan)
    } else {
        // The yuan side was not read with this HKD balance.
        Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.SpaceBetween) {
            Text(tr("CNY Balance"), color = secondary)
            Text(tr("Unavailable"), color = secondary, modifier = Modifier.padding(start = 16.dp))
        }
    }
    BalanceValueRow(
        tr("Exchange Rate"), dual.rateText,
        Modifier.clearAndSetSemantics {
            contentDescription = context.tr("Exchange rate: 1 Hong Kong dollar equals ${dual.exchangeRate.rate} Chinese yuan.")
        },
    )
    val expired = dual.exchangeRate.isExpired()
    // Once the rate has expired the hour no longer matters, so the row keeps to one line.
    val date = dual.exchangeRate.expiryText(includeTime = !expired) ?: return
    if (expired) {
        val warning = if (isSystemInDarkTheme()) Color(0xFFFF9F0A) else Color(0xFFFF9500)
        Row(
            Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(tr("Rate Valid Until"), color = secondary)
            Row(
                Modifier.padding(start = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Warning, contentDescription = null, tint = warning, modifier = Modifier.size(14.dp))
                Text(tr("Expired $date"), color = warning, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.End)
            }
        }
    } else {
        BalanceValueRow(tr("Rate Valid Until"), date)
    }
}

@Composable
private fun BalanceValueRow(title: String, value: String, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.End, modifier = Modifier.padding(start = 16.dp))
    }
}

@Composable
fun CardListItem(
    card: SavedCardRecord,
    transactionCount: Int,
    tripCount: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ElevatedCard(
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 1.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(10.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            WalletCard(
                card = card,
                mode = WalletCardMode.Compact,
                modifier = Modifier.width(168.dp),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    cardTitle(card),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    card.displayedSerialNumber,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (card.visibleBalance.isNotBlank()) {
                    Text(
                        tr(card.visibleBalance),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CountPill("$transactionCount Tx")
                    CountPill("$tripCount Trips")
                }
            }
        }
    }
}

@Composable
private fun CountPill(label: String) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
    ) {
        Text(
            tr(label),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

@Composable
private fun BoxScope.FrostedHeader(face: @Composable (Modifier) -> Unit) {
    // Blurs and darkens the top strip of a card design so its own logos never sit under the
    // name, number and balance; the strip matches the part of a stacked card that stays visible.
    BoxWithConstraints(Modifier.matchParentSize()) {
        val height = maxHeight.value.coerceAtLeast(1f)
        fun at(points: Float) = (points / height).coerceIn(0f, 1f)
        face(
            Modifier
                .matchParentSize()
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    drawRect(
                        Brush.verticalGradient(0f to Color.Black, at(50f) to Color.Black, at(80f) to Color.Transparent),
                        blendMode = BlendMode.DstIn,
                    )
                }
                .blur(14.dp, BlurredEdgeTreatment.Rectangle),
        )
        Box(
            Modifier.matchParentSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.46f),
                    at(52f) to Color.Black.copy(alpha = 0.34f),
                    at(82f) to Color.Transparent,
                    maxOf(at(82f), at(height - 60f)) to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.22f),
                ),
            ),
        )
    }
}

/** The iOS card-icon symbols, drawn with the closest Material icon. */
val markerSymbols: List<Pair<String, ImageVector>> = listOf(
    "sf:bus.fill" to Icons.Filled.DirectionsBus,
    "sf:tram.fill" to Icons.Filled.Tram,
    "sf:train.side.front.car" to Icons.Filled.Train,
    "sf:ferry.fill" to Icons.Filled.DirectionsBoat,
    "sf:bicycle" to Icons.Filled.PedalBike,
    "sf:creditcard.fill" to Icons.Filled.CreditCard,
    "sf:star.fill" to Icons.Filled.Star,
    "sf:heart.fill" to Icons.Filled.Favorite,
    "sf:tag.fill" to Icons.Filled.LocalOffer,
    "sf:briefcase.fill" to Icons.Filled.Work,
    "sf:map.fill" to Icons.Filled.Map,
    "sf:mappin" to Icons.Filled.Place,
    "sf:house.fill" to Icons.Filled.Home,
    "sf:lock.fill" to Icons.Filled.Lock,
    "sf:iphone" to Icons.Filled.PhoneIphone,
    "sf:bolt.fill" to Icons.Filled.Bolt,
    "sf:leaf.fill" to Icons.Filled.Eco,
    "sf:ticket.fill" to Icons.Filled.ConfirmationNumber,
    "sf:bag.fill" to Icons.Filled.ShoppingBag,
    "sf:cart.fill" to Icons.Filled.ShoppingCart,
    "sf:airplane" to Icons.Filled.Flight,
    "sf:antenna.radiowaves.left.and.right" to Icons.Filled.SettingsInputAntenna,
    "sf:camera.fill" to Icons.Filled.PhotoCamera,
    "sf:flashlight.on.fill" to Icons.Filled.FlashlightOn,
    "sf:music.note" to Icons.Filled.MusicNote,
    "sf:video.fill" to Icons.Filled.Videocam,
    "sf:gamecontroller.fill" to Icons.Filled.SportsEsports,
    "sf:building.fill" to Icons.Filled.Business,
    "sf:fuelpump.fill" to Icons.Filled.LocalGasStation,
    "sf:cup.and.saucer.fill" to Icons.Filled.LocalCafe,
    "sf:pawprint.fill" to Icons.Filled.Pets,
    "sf:graduationcap.fill" to Icons.Filled.School,
)

private val markerSymbolIcons = markerSymbols.toMap()

fun markerIcon(symbolName: String?): ImageVector =
    symbolName?.let(markerSymbolIcons::get) ?: Icons.Filled.CreditCard

@Composable
fun MarkerBadge(card: SavedCardRecord, showsDefault: Boolean, size: androidx.compose.ui.unit.Dp = 28.dp) {
    val markerText = card.markerText
    val markerIcon = card.markerSystemName
    if (markerText == null && markerIcon == null) {
        if (showsDefault) {
            Icon(Icons.Filled.Train, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
        }
        return
    }
    val markerShape = if (card.markerShape.name == "square") RoundedCornerShape(size / 4) else CircleShape
    Box(
        modifier = Modifier
            .size(size)
            .background(card.markerColor.toColor(), markerShape),
        contentAlignment = Alignment.Center,
    ) {
        if (markerText != null) {
            Text(
                markerText.take(2),
                color = card.markerOuterColor.toColor(),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
            )
        } else {
            Icon(markerIcon(card.markerSymbolName), contentDescription = null, tint = card.markerOuterColor.toColor(), modifier = Modifier.size(size * 4 / 7))
        }
    }
}

fun cardBrush(card: SavedCardRecord, color: Color, design: ad.neko.cardbal.android.data.SavedCardDesign = card.design): Brush {
    return if (design.name == "sunrise") {
        Brush.linearGradient(listOf(color, color.copy(alpha = 0.9f), Color(0xFFE9893A), color.copy(alpha = 0.62f)))
    } else {
        Brush.linearGradient(listOf(color, color.copy(alpha = 0.74f), Color(0xFF242936)))
    }
}

fun ad.neko.cardbal.android.data.SavedCardColor.toColor(): Color {
    return Color(red = red.toFloat(), green = green.toFloat(), blue = blue.toFloat())
}

@Composable
fun CompactCardRow(card: SavedCardRecord, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.CreditCard, contentDescription = null)
        }
        Column(Modifier.weight(1f)) {
            Text(cardTitle(card), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(card.displayedSerialNumber, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(tr(card.visibleBalance), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    }
}
