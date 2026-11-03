package com.photobridge.photobridge

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Also the target of Android's Share menu: shared files are copied into the
 * cache and handed to Dart on request (`takeShared`), so none are lost while
 * Flutter starts.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val shared = mutableListOf<String>()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "photobridge/files").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeShared") {
                    result.success(shared.toList())
                    shared.clear()
                } else {
                    result.notImplemented()
                }
            }
        }
        receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    private fun receive(intent: Intent?) {
        val uris = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.stream())
            Intent.ACTION_SEND_MULTIPLE -> intent.streams()
            else -> return
        }
        // Handled once, not again when the activity is recreated.
        intent.action = null
        if (uris.isEmpty()) return
        thread {
            val paths = uris.mapNotNull(::copyToCache)
            main.post {
                if (paths.isEmpty()) return@post
                shared += paths
                channel?.invokeMethod("sharedAvailable", null)
            }
        }
    }

    private fun copyToCache(uri: Uri): String? = try {
        val dir = File(cacheDir, "shared/${UUID.randomUUID()}").apply { mkdirs() }
        val dest = File(dir, displayName(uri))
        contentResolver.openInputStream(uri)?.use { input ->
            dest.outputStream().use { input.copyTo(it) }
        } ?: return null
        dest.path
    } catch (e: Exception) {
        null
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) {
                val name = it.getString(0)
                if (!name.isNullOrBlank()) return name.replace('/', '_')
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.ifBlank { null } ?: "shared_file"
    }

    @Suppress("DEPRECATION")
    private fun Intent.stream(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun Intent.streams(): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()
}
