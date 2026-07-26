import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val releaseSigningPropertiesFile = providers.gradleProperty("releaseSigningPropertiesFile")
    .orNull
    ?.let(::file)
    ?: rootProject.file("key.properties")
if (releaseSigningPropertiesFile.isFile && releaseSigningPropertiesFile.canRead()) {
    FileInputStream(releaseSigningPropertiesFile).use(keystoreProperties::load)
}

val requiredReleaseSigningProperties = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)
val releaseSigningValues = requiredReleaseSigningProperties.associateWith { propertyName ->
    keystoreProperties.getProperty(propertyName)?.trim()?.takeIf(String::isNotEmpty)
}
val releaseStoreFile = releaseSigningValues["storeFile"]?.let { storeFile ->
    File(releaseSigningPropertiesFile.parentFile, storeFile)
}
val invalidReleaseSigningInputs = buildList {
    requiredReleaseSigningProperties.filterTo(this) { releaseSigningValues[it] == null }
    if (releaseStoreFile != null &&
        (!releaseStoreFile.isFile || !releaseStoreFile.canRead()) &&
        "storeFile" !in this
    ) {
        add("storeFile")
    }
}
val releaseSigningIsValid = invalidReleaseSigningInputs.isEmpty()

val validateReleaseSigning = tasks.register("validateReleaseSigning") {
    doLast {
        check(releaseSigningIsValid) {
            "Release signing configuration is required for release builds. " +
                "Missing or invalid inputs: ${invalidReleaseSigningInputs.joinToString(", ")}."
        }
    }
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
        if (releaseSigningIsValid) {
            create("release") {
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
                storeFile = releaseStoreFile
                storePassword = releaseSigningValues.getValue("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningIsValid) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

tasks.configureEach {
    if (name.matches(Regex("pre.*ReleaseBuild"))) {
        dependsOn(validateReleaseSigning)
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

dependencies {
    testImplementation("junit:junit:4.13.2")
    // Backports java.time (and friends) for flutter_local_notifications when
    // core library desugaring is enabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // AXI KEYBOARD (IME): sherpa-onnx Kotlin API (see the download task above).
    implementation(files(sherpaOnnxAar))
}
