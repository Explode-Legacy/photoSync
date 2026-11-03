package com.photobridge.pb_device

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Battery level and charging state, from the sticky ACTION_BATTERY_CHANGED broadcast. */
class PbDevicePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context: Context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "pb_device").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "battery") return@setMethodCallHandler result.notImplemented()
                val status = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val level = status?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = status?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
                val plugged = status?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
                result.success(
                    mapOf(
                        "level" to if (level < 0 || scale <= 0) -1 else level * 100 / scale,
                        "charging" to (plugged != 0),
                    ),
                )
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
