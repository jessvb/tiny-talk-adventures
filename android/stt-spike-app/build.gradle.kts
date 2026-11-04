plugins {
    id("com.android.application")
}

// THROWAWAY measurement module for issue #88 (on-device STT spike). Not shipped.
android {
    namespace = "com.jessvb.tinytalk.sttspike"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.jessvb.tinytalk.sttspike"
        minSdk = 26
        targetSdk = 33
        versionCode = 1
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
    }

    packaging { jniLibs { useLegacyPackaging = true } }
}

dependencies {
    implementation(files("../stt-spike/downloads/libs/sherpa-onnx-1.13.8.aar"))
    implementation("com.alphacephei:vosk-android:0.3.75")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
