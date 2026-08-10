import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.lifeos.lifeos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (self-hosted OTA update
        // notifications) — it uses java.time APIs that must be desugared for
        // the app's minSdk.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lifeos.lifeos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Roadmap SLICE 1 (flutter_gemma on-device LLM): ship only the 64-bit
        // ARM ABI. The litert-lm runtime is arm64-v8a; this keeps the APK from
        // bundling unsupported ABIs.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// AXI KEYBOARD (IME): the keyboard service runs OUTSIDE the Flutter engine, so
// it needs sherpa-onnx's Kotlin/JNI API. The `sherpa_onnx` Dart plugin only
// ships the C-API .so files (no Java classes), so we add the official prebuilt
// AAR from the sherpa-onnx GitHub release:
//   * SAME version as the Dart plugin (keep in lockstep with pubspec.lock);
//   * the *static-link-onnxruntime* variant, whose libsherpa-onnx-jni.so has
//     onnxruntime linked IN — no second libonnxruntime.so, so it cannot clash
//     with the one the Dart plugin already packages.
// The AAR (~37 MB, all ABIs; abiFilters keeps only arm64 in the APK) is NOT
// committed — this task fetches it into app/libs/ on first build.
val sherpaOnnxVersion = "1.13.4"
val sherpaOnnxAar = file("libs/sherpa-onnx-static-link-onnxruntime-$sherpaOnnxVersion.aar")
val downloadSherpaOnnxAar = tasks.register("downloadSherpaOnnxAar") {
    outputs.file(sherpaOnnxAar)
    doLast {
        // Size floor: a captive-portal page or truncated download is tiny.
        if (sherpaOnnxAar.exists() && sherpaOnnxAar.length() > 10_000_000L) return@doLast
        sherpaOnnxAar.parentFile.mkdirs()
        val url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/" +
            "v$sherpaOnnxVersion/sherpa-onnx-static-link-onnxruntime-$sherpaOnnxVersion.aar"
        uri(url).toURL().openStream().use { input: java.io.InputStream ->
            sherpaOnnxAar.outputStream().use { output -> input.copyTo(output) }
        }
        check(sherpaOnnxAar.length() > 10_000_000L) {
            "sherpa-onnx AAR download looks truncated: ${sherpaOnnxAar.length()} bytes"
        }
    }
}
tasks.named("preBuild") { dependsOn(downloadSherpaOnnxAar) }

// ANDROID MUST GET ZETETIC'S libsqlcipher.so, NOT THE DESKTOP ONE.
//
// Two different libraries ship under the same file name:
//   * net.zetetic:sqlcipher-android (an AAR dependency of sqflite_sqlcipher)
//     carries the JNI layer Android calls through — 12 zetetic/JNI references
//     in the binary, 5 746 024 bytes.
//   * the `sqlite3` Dart CODE ASSET, built with `source: sqlcipher` (pubspec
//     `hooks: user_defines:`) for the Linux FFI backend, is a pure FFI build
//     with ZERO JNI references, 5 939 008 bytes. `copyJniLibsflutterBuild<V>`
//     stages it into build/app/generated/jniLibs/, from where packaging merges
//     it by name — and it won.
//
// So on Android every native method of
// net.zetetic.database.sqlcipher.SQLiteConnection was unbound and the app died
// opening its encrypted database before the first frame:
//
//   java.lang.UnsatisfiedLinkError: No implementation found for
//   net.zetetic.database.sqlcipher.SQLiteConnection.nativeOpen(...)
//
// pubspec.yaml called that asset "inert weight" on mobile and the mobile open
// path "untouched". It was neither: it was fatal, and it shipped to a real
// phone twice before an emulator run caught it.
//
// Removed from the STAGING DIR of its own producer, deliberately, rather than
// with `packaging { jniLibs { excludes } }` (which would drop both files,
// since they share a name) or `pickFirsts` (which depends on merge order — not
// a guarantee to hang a database on). If the producer ever stops emitting it,
// this says so instead of silently doing nothing.
tasks.matching { it.name.startsWith("copyJniLibsflutterBuild") }.configureEach {
    doLast {
        val staged = layout.buildDirectory.get().asFile
            .resolve("generated/jniLibs")
        val victims = staged.walkTopDown()
            .filter { it.name == "libsqlcipher.so" }
            .toList()
        if (victims.isEmpty()) {
            logger.lifecycle(
                "sqlcipher: no desktop code asset staged in ${staged.path} — " +
                "either the pubspec hook stopped emitting it (this task can go) " +
                "or the staging path moved (Android is about to lose its JNI " +
                "library again)."
            )
        }
        victims.forEach {
            logger.lifecycle("sqlcipher: dropping desktop code asset ${it.path}")
            it.delete()
        }
    }
}

dependencies {
    // Backports java.time (and friends) for flutter_local_notifications when
    // core library desugaring is enabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // AXI KEYBOARD (IME): sherpa-onnx Kotlin API (see the download task above).
    implementation(files(sherpaOnnxAar))
}
