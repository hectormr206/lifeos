package com.lifeos.lifeos

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Optional biometric app lock: local_auth's Android implementation shows the
// system BiometricPrompt, which requires the host Activity to be a
// FragmentActivity (it attaches a fragment to run the prompt). Flutter's
// default FlutterActivity is NOT a FragmentActivity, so we switch to
// FlutterFragmentActivity — otherwise authenticate() throws
// "local_auth requires activity to be a FragmentActivity" at runtime. The
// existing dictation MethodChannel below is unchanged.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // APP LOCK secure-surface toggle: while the optional biometric app lock
        // is ENABLED, the Dart lock controller turns FLAG_SECURE on so Android's
        // Recents/task snapshot (captured around onPause, BEFORE the Dart-side
        // re-lock can draw a lock frame) and manual screenshots can never show
        // the on-device data. Toggled — not always-on — so users who never opt
        // into the lock keep normal screenshot ability.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lifeos/app_lock",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureFlag" -> {
                    val enable = call.arguments as? Boolean ?: false
                    if (enable) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
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
