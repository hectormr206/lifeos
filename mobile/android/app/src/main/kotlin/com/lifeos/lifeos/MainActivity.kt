package com.lifeos.lifeos

import android.content.Context
import android.content.Intent
import android.os.Bundle
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

    // DEVICE ASSISTANT (Etapa 1): when the user sets LifeOS as the digital
    // assistant, long-pressing power / the assistant gesture delivers
    // ACTION_ASSIST here. Two arrival paths (the activity is singleTask):
    //   * COLD START (process dead): the assist intent is the launch intent —
    //     onCreate sees it, but Dart is not up yet, so we only latch
    //     [pendingAssistLaunch]; Flutter pulls it once via
    //     "consumeAssistLaunch" after its first frame.
    //   * WARM RESUME (app backgrounded): onNewIntent fires with the engine
    //     alive — push the event straight to Dart over [assistantChannel]
    //     (no latch, so a later cold-start pull can't double-fire).
    // Dart then routes to /chat with the mic armed; the app-lock gate wraps
    // every route on the Flutter side, so an assist launch NEVER bypasses auth.
    private var assistantChannel: MethodChannel? = null
    private var pendingAssistLaunch = false

    private fun isAssistIntent(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_ASSIST

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isAssistIntent(intent)) pendingAssistLaunch = true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isAssistIntent(intent)) {
            val channel = assistantChannel
            if (channel != null) {
                channel.invokeMethod("assistLaunch", null)
            } else {
                pendingAssistLaunch = true
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // DEVICE ASSISTANT channel: cold-start pull ("consumeAssistLaunch"),
        // warm-resume push ("assistLaunch" — invoked from onNewIntent above),
        // and the Ajustes deep-link to the system default-assistant screen.
        assistantChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lifeos/assistant",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // One-shot: was this launch (cold start) an assist launch?
                    "consumeAssistLaunch" -> {
                        val pending = pendingAssistLaunch
                        pendingAssistLaunch = false
                        result.success(pending)
                    }
                    // Ajustes → "Usar a Axi como asistente del teléfono":
                    // open the system screen where the default assistant is
                    // chosen. ACTION_VOICE_INPUT_SETTINGS lands closest on
                    // most OEMs; fall back to the default-apps manager.
                    "openAssistantSettings" -> {
                        val opened = try {
                            startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS))
                            true
                        } catch (_: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
                                true
                            } catch (_: Exception) {
                                false
                            }
                        }
                        result.success(opened)
                    }
                    else -> result.notImplemented()
                }
            }
        }
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
