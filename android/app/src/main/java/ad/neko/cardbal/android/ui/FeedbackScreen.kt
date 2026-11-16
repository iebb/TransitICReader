package ad.neko.cardbal.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import ad.neko.cardbal.android.data.AirFeedbackConfig
import ad.neko.cardbal.android.data.AirFeedbackEnvironment
import ad.neko.cardbal.android.data.AirFeedbackException
import ad.neko.cardbal.android.data.FeedbackClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException

/** A screenshot ready to send (JPEG, at most 2048 px on the long side) and its preview. */
private class FeedbackAttachment(val jpeg: ByteArray, val preview: ImageBitmap)

/**
 * Send Feedback, as on iPhone: a message and up to four screenshots go to the developer's
 * AirFeedback inbox with the app version, device model, Android version and locale.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedbackScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var message by rememberSaveable { mutableStateOf("") }
    val attachments = remember { mutableStateListOf<FeedbackAttachment>() }
    var sending by remember { mutableStateOf(false) }
    var loadingImages by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var sent by remember { mutableStateOf(false) }
    BackHandler(enabled = !sending, onBack = onBack)

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(AirFeedbackConfig.MAXIMUM_IMAGES),
    ) { uris ->
        val wanted = uris.take(AirFeedbackConfig.MAXIMUM_IMAGES - attachments.size)
        if (wanted.isEmpty()) return@rememberLauncherForActivityResult
        loadingImages = true
        scope.launch {
            val loaded = withContext(Dispatchers.IO) { wanted.mapNotNull { runCatching { attachment(context, it) }.getOrNull() } }
            attachments.addAll(loaded.take(AirFeedbackConfig.MAXIMUM_IMAGES - attachments.size))
            // An Android-only message (Localization.kt), shared with the card face picker.
            val importFailed = "Could not import this photo. Try another image."
            if (loaded.size < wanted.size) failure = context.tr(importFailed)
            loadingImages = false
        }
    }
    val canSend = !sending && !loadingImages && FeedbackClient.canSend(message, attachments.size)

    fun send() {
        sending = true
        failure = null
        val images = attachments.map { it.jpeg }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { FeedbackClient().send(message, images, AirFeedbackEnvironment.current()) }
            }
            result.onSuccess { sent = true }.onFailure { error ->
                failure = when (error) {
                    is AirFeedbackException -> error.reason ?: context.tr("The server answered ${error.status}.")
                    else -> context.tr("Could not send. Check your connection and try again.")
                }
            }
            sending = false
        }
    }

    Column(modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(tr("Send Feedback")) },
            navigationIcon = {
                IconButton(onClick = onBack, enabled = !sending) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = tr("Back"))
                }
            },
            actions = {
                if (sending) {
                    CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(24.dp), strokeWidth = 2.dp)
                } else {
                    TextButton(onClick = ::send, enabled = canSend, modifier = Modifier.testTag("feedback-send")) {
                        Text(tr("Send"))
                    }
                }
            },
        )
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            OutlinedTextField(
                value = message,
                onValueChange = { message = it.take(AirFeedbackConfig.MAXIMUM_MESSAGE_LENGTH) },
                placeholder = { Text(tr("What happened, or what would you like to see?")) },
                enabled = !sending,
                minLines = 5,
                maxLines = 12,
                modifier = Modifier.fillMaxWidth().testTag("feedback-message"),
            )
            if (attachments.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    attachments.forEachIndexed { index, attachment ->
                        Box(Modifier.size(72.dp)) {
                            Image(
                                attachment.preview,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp)),
                            )
                            IconButton(
                                onClick = { attachments.removeAt(index) },
                                enabled = !sending,
                                modifier = Modifier.align(Alignment.TopEnd).size(28.dp),
                            ) {
                                Icon(
                                    Icons.Filled.Close,
                                    contentDescription = tr("Remove Screenshot"),
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp).background(Color.Black.copy(alpha = 0.6f), CircleShape),
                                )
                            }
                        }
                    }
                }
            }
            OutlinedButton(
                onClick = {
                    failure = null
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                },
                enabled = !sending && !loadingImages && attachments.size < AirFeedbackConfig.MAXIMUM_IMAGES,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                if (loadingImages) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.AddPhotoAlternate, contentDescription = null, modifier = Modifier.size(18.dp))
                }
                Text(tr("Add Screenshots"), modifier = Modifier.padding(start = 8.dp))
            }
            Text(
                tr("Up to ${AirFeedbackConfig.MAXIMUM_IMAGES} images. The app version, device model, system version and language are sent along."),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            failure?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }

    if (sent) {
        AlertDialog(
            onDismissRequest = onBack,
            title = { Text(tr("Thank you")) },
            text = { Text(tr("Your feedback was sent.")) },
            confirmButton = { TextButton(onClick = onBack) { Text(tr("Done")) } },
        )
    }
}

/** Decodes a picked image upright and re-encodes it as the iPhone form does: 2048 px, JPEG 80%. */
private fun attachment(context: Context, uri: Uri): FeedbackAttachment {
    val resolver = context.contentResolver
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: throw IOException("Photo is unavailable")
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Photo is not a supported image" }
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_DIMENSION) sample *= 2
    val decoded = resolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
    } ?: throw IOException("Photo could not be decoded")
    val orientation = runCatching {
        resolver.openInputStream(uri)?.use {
            ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }
    }.getOrNull() ?: ExifInterface.ORIENTATION_NORMAL
    val scale = (MAX_DIMENSION.toFloat() / maxOf(decoded.width, decoded.height)).coerceAtMost(1f)
    val matrix = Matrix().apply {
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
        }
        postScale(scale, scale)
    }
    val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
    if (upright !== decoded) decoded.recycle()
    val jpeg = ByteArrayOutputStream().use { output ->
        if (!upright.compress(Bitmap.CompressFormat.JPEG, 80, output)) throw IOException("Photo could not be encoded")
        output.toByteArray()
    }
    val previewScale = (PREVIEW_DIMENSION.toFloat() / maxOf(upright.width, upright.height)).coerceAtMost(1f)
    val preview = Bitmap.createScaledBitmap(
        upright,
        (upright.width * previewScale).toInt().coerceAtLeast(1),
        (upright.height * previewScale).toInt().coerceAtLeast(1),
        true,
    )
    if (preview !== upright) upright.recycle()
    return FeedbackAttachment(jpeg, preview.asImageBitmap())
}

private const val MAX_DIMENSION = 2048
private const val PREVIEW_DIMENSION = 216
