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

        buildConfigField("String", "GROQ_API_KEY", "\"${secret("GROQ_API_KEY")}\"")
        buildConfigField("String", "CLOUDFLARE_ACCOUNT_ID", "\"${secret("CLOUDFLARE_ACCOUNT_ID")}\"")
        buildConfigField("String", "CLOUDFLARE_API_TOKEN", "\"${secret("CLOUDFLARE_API_TOKEN")}\"")
        buildConfigField("String", "API_NINJAS_KEY", "\"${secret("API_NINJAS_KEY")}\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":core"))

    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")

    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.31.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
