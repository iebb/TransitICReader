package ad.neko.cardbal.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Train
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ad.neko.cardbal.android.data.SavedCardRecord

enum class WalletCardMode { Hero, Compact }

@Composable
fun WalletCard(card: SavedCardRecord, modifier: Modifier = Modifier, mode: WalletCardMode = WalletCardMode.Hero) {
    val context = LocalContext.current
    val importedImage = remember(card.faceImageFileName) {
        importedFaceImageFor(context, card.faceImageFileName)
    }?.takeIf { card.finalIsUsingImage }
    val image = presetDrawableFor(card.faceImageFileName ?: card.cardFamily)?.takeIf { card.finalIsUsingImage || card.faceImageFileName == null }
    // Published faces fill in cards with no imported photo or bundled preset.
    val bitmap = importedImage ?: if (image == null) rememberRemoteFace(card) else null
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
            if (bitmap != null) {
                Image(
                    bitmap = bitmap,
                    contentDescription = null,
                    modifier = Modifier.matchParentSize(),
                    contentScale = ContentScale.Crop,
                )
                Box(
                    Modifier.matchParentSize().background(
                        Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.28f), Color.Transparent, Color.Black.copy(alpha = 0.32f))),
                    ),
                )
            } else if (image != null) {
                Image(
                    painter = painterResource(image),
                    contentDescription = null,
                    modifier = Modifier.matchParentSize(),
                    contentScale = ContentScale.Crop,
                )
                Box(
                    Modifier.matchParentSize().background(
                        Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.28f), Color.Transparent, Color.Black.copy(alpha = 0.32f))),
                    ),
                )
            } else {
                Box(
                    Modifier.matchParentSize().background(
                        cardBrush(card, color),
                    ),
                )
            }

            if (mode == WalletCardMode.Compact) {
                Box(Modifier.matchParentSize().padding(12.dp), contentAlignment = Alignment.TopStart) {
                    MarkerBadge(card)
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
                                MarkerBadge(card)
                                if (!card.finalHideTitle && importedImage == null) {
                                    Text(
                                        card.displayTitle,
                                        color = titleColor,
                                        style = MaterialTheme.typography.titleLarge,
                                        fontWeight = FontWeight.Bold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                            if (!card.finalHideSerialNumber) {
                                Text(
                                    card.displayedSerialNumber,
                                    color = titleColor.copy(alpha = 0.82f),
                                    style = MaterialTheme.typography.bodyMedium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }

                        if (card.visibleBalance.isNotBlank()) {
                            Text(
                                card.visibleBalance,
                                color = balanceColor,
                                style = MaterialTheme.typography.headlineSmall,
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
                    card.displayTitle,
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
                        card.visibleBalance,
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
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

@Composable
private fun MarkerBadge(card: SavedCardRecord) {
    val markerText = card.markerText
    val markerIcon = card.markerSystemName
    if (markerText == null && markerIcon == null) {
        Icon(Icons.Filled.Train, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
        return
    }
    val markerShape = if (card.markerShape.name == "square") RoundedCornerShape(7.dp) else CircleShape
    Box(
        modifier = Modifier
            .size(28.dp)
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
            Icon(Icons.Filled.CreditCard, contentDescription = null, tint = card.markerOuterColor.toColor(), modifier = Modifier.size(16.dp))
        }
    }
}

private fun cardBrush(card: SavedCardRecord, color: Color): Brush {
    return if (card.design.name == "sunrise") {
        Brush.linearGradient(listOf(color, color.copy(alpha = 0.9f), Color(0xFFE9893A), color.copy(alpha = 0.62f)))
    } else {
        Brush.linearGradient(listOf(color, color.copy(alpha = 0.74f), Color(0xFF242936)))
    }
}

private fun ad.neko.cardbal.android.data.SavedCardColor.toColor(): Color {
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
            Text(card.displayTitle, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(card.displayedSerialNumber, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(card.visibleBalance, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    }
}
