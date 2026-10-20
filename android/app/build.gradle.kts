plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.jessvb.tinytalk"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.jessvb.tinytalk"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")

    testImplementation("junit:junit:4.13.2")
}
