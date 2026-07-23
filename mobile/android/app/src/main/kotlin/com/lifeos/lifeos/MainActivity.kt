package com.lifeos.lifeos

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // AXI KEYBOARD (IME) setup helpers for the Flutter dictation screen:
        // enabling an IME and opening the system keyboard picker have no
        // Flutter API, so the screen calls through this small channel.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lifeos/dictation",
        ).setMethodCallHandler { call, result ->
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            when (call.method) {
                // Step 1: system screen where the user toggles "Axi" on.
                "openImeSettings" -> {
                    startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                    result.success(null)
                }
                // Step 2: system picker to actually switch to the Axi keyboard.
                "showImePicker" -> {
                    imm.showInputMethodPicker()
                    result.success(null)
                }
                // Whether the Axi IME is enabled in system settings.
                "isImeEnabled" -> result.success(
                    imm.enabledInputMethodList.any { it.packageName == packageName },
                )
                // Whether the Axi IME is the CURRENT keyboard.
                "isImeSelected" -> result.success(
                    Settings.Secure.getString(
                        contentResolver,
                        Settings.Secure.DEFAULT_INPUT_METHOD,
                    )?.startsWith("$packageName/") == true,
                )
                else -> result.notImplemented()
            }
        }
    }
}
