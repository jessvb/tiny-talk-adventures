import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Secrets come from android/local.secrets.properties (gitignored). Missing file or key -> "".
// Values are never printed. NOTE: they end up inside the APK; use dedicated, revocable keys.
val secrets = Properties().apply {
    val f = rootProject.file("local.secrets.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun secret(name: String): String =
    (secrets.getProperty(name) ?: "").trim().replace("\\", "\\\\").replace("\"", "\\\"")

// ---- On-device speech recognition (Whisper tiny.en via sherpa-onnx), issue #88 ----
// Large downloads, never committed (android/stt-spike/.gitignore). The STATIC-LINK sherpa AAR
// links ONNX Runtime into libsherpa-onnx-jni.so, so it does not ship a second
// lib/arm64-v8a/libonnxruntime.so next to onnxruntime-android's (which SileroVad uses).
val sttDownloads = rootProject.file("stt-spike/downloads")
val sherpaAar = File(sttDownloads, "libs/sherpa-onnx-static-link-onnxruntime-1.13.8.aar")
val whisperFiles = listOf("tiny.en-encoder.int8.onnx", "tiny.en-decoder.int8.onnx", "tiny.en-tokens.txt")
    .map { File(sttDownloads, "models/whisper-tiny.en/$it") }

/**
 * Checks the downloads exist (fails BEFORE compiling, with an actionable message), then copies
 * the Whisper model into a generated assets dir (APK path assets/stt/whisper-tiny.en/).
 */
abstract class SttModelAssets : DefaultTask() {
    @get:InputFiles @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val modelFiles: ConfigurableFileCollection
    @get:Internal abstract val aar: Property<File>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun run() {
        val files = modelFiles.files.toList()
        val missing = (listOf(aar.get()) + files).filterNot { it.isFile }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "On-device listening needs files that are downloaded, not committed. Missing:\n" +
                    missing.joinToString("\n") { "  - $it" } +
                    "\nFetch them once, from the repo root:\n" +
                    "  INCLUDE_OPTIONAL=1 bash android/stt-spike/fetch-models.sh\n" +
                    "(INCLUDE_OPTIONAL=1 also fetches the static-link sherpa-onnx AAR.) " +
                    "./gradlew :core:test works without them.",
            )
        }
        val root = outputDir.get().asFile
        root.deleteRecursively()
        val dest = root.resolve("stt/whisper-tiny.en").apply { mkdirs() }
        files.forEach { it.copyTo(dest.resolve(it.name), overwrite = true) }
    }
}

val sttModelAssets = tasks.register<SttModelAssets>("sttModelAssets") {
    modelFiles.from(whisperFiles)
    aar.set(sherpaAar)
    outputDir.set(layout.buildDirectory.dir("generated/sttModel"))
}
// Runs before anything compiles, so a fresh clone fails with the message above, not with
// unresolved com.k2fsa imports.
tasks.named("preBuild") { dependsOn(sttModelAssets) }

android {
    namespace = "com.jessvb.tinytalk"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.jessvb.tinytalk"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Pixel 3 / modern phones only: drops the x86/armv7 copies of two native runtimes.
        ndk { abiFilters += "arm64-v8a" }

        buildConfigField("String", "GROQ_API_KEY", "\"${secret("GROQ_API_KEY")}\"")
        buildConfigField("String", "CLOUDFLARE_ACCOUNT_ID", "\"${secret("CLOUDFLARE_ACCOUNT_ID")}\"")
        buildConfigField("String", "CLOUDFLARE_API_TOKEN", "\"${secret("CLOUDFLARE_API_TOKEN")}\"")
        buildConfigField("String", "API_NINJAS_KEY", "\"${secret("API_NINJAS_KEY")}\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            // abiFilters (above) applies at packaging, AFTER native libs merge. The static-link
            // AAR still carries a stray jni/x86/libonnxruntime.so that collides with
            // onnxruntime-android's x86 copy during the merge, so drop the ABIs this app never
            // ships before they merge. arm64-v8a is untouched (no pickFirsts): there the AAR has
            // only libsherpa-onnx-jni.so, and libonnxruntime.so comes from onnxruntime-android.
            excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**")
        }
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(sttModelAssets, SttModelAssets::outputDir)
    }
}

dependencies {
    implementation(project(":core"))

    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    // App container (TinyTalkViewModel): latest stable lifecycle, verified 2026-10-22.
    implementation("androidx.lifecycle:lifecycle-viewmodel:2.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // SileroVad uses ONNX Runtime's Java API directly.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.31.0")
    // Whisper tiny.en (on-device listening). Static-link variant: see the note at the top.
    implementation(files(sherpaAar))

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
