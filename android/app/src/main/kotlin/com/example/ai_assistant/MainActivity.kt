package com.example.ai_assistant

import android.os.Environment
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Free/total storage for the `get_device_info` tool (004 R4). A ~10-line StatFs read over a
// MethodChannel — the in-repo alternative to the unmaintained 0.x `disk_space_plus` (Principle IX).
// Read-only, no permissions. The Dart side (PlatformDeviceInfoToolService) degrades a missing
// channel / error to "unknown" rather than crashing.
class MainActivity : FlutterActivity() {
    private val storageChannel = "ai_assistant/device_storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getStorage") {
                    val stat = StatFs(Environment.getDataDirectory().path)
                    result.success(
                        mapOf(
                            "freeBytes" to stat.availableBytes,
                            "totalBytes" to stat.totalBytes,
                        )
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
}
