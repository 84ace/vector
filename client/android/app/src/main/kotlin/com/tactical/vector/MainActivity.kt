package com.tactical.vector

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "vector/background"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(startMeshService())
                "stop" -> {
                    stopMeshService()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Returns false rather than throwing when the service cannot be started.
     *
     * Android 12+ refuses to start a foreground service from the background, and
     * Android 14+ refuses a location-typed one unless the location permission is
     * held. Both are ordinary states for this app — the operator may have denied
     * location — so Dart treats a false as "no background comms" and says so in
     * the event log, rather than the app dying.
     */
    private fun startMeshService(): Boolean {
        val intent = Intent(this, MeshForegroundService::class.java).apply {
            action = MeshForegroundService.ACTION_START
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopMeshService() {
        stopService(Intent(this, MeshForegroundService::class.java))
    }
}
