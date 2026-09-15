package com.lifeos.lifeos

import android.content.Context
import com.github.dart_lang.jni.JniPlugin
import com.github.dart_lang.jni_flutter.JniFlutterPlugin
import com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin
import dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Probe-only host: never attach production background or bootstrap plugins. */
class SecurityProbeActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        // Disable constructor-level automatic registration as well as the
        // Activity's GeneratedPluginRegistrant path. This engine is not cached.
        return FlutterEngine(context, null, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Deliberately no super call: it registers the entire production plugin
        // set, including background_downloader's eager WorkManager attachment.
        // Dart-side path_provider requires both native JNI integrations.
        flutterEngine.plugins.add(JniPlugin())
        flutterEngine.plugins.add(JniFlutterPlugin())
        flutterEngine.plugins.add(FlutterSecureStoragePlugin())
        flutterEngine.plugins.add(PackageInfoPlugin())
    }

    // provideFlutterEngine marks it host-provided; retain Activity ownership so
    // destruction cannot leave a live probe engine or plugins behind.
    override fun shouldDestroyEngineWithHost(): Boolean = true
}
