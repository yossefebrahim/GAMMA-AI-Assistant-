plugins {
    id("com.android.application")
    // KGP is applied by the Flutter Gradle Plugin (built-in-Kotlin migration); applying
    // kotlin-android here explicitly is warned against by flutter_tools and will break in
    // future Flutter versions.
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ai_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        applicationId = "com.example.ai_assistant"
        // Baseline per plan.md / constitution §V: Android 10 (API 29, FBE-enforced at-rest
        // encryption) and arm64-v8a only (the only ABI we ship the ~2.4 GB model runtime for).
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // flutter_gemma 0.15.3 bundles MediaPipe/LiteRT-LM, which references optional classes
            // (com.google.mediapipe.proto.*, auto.value.Memoized) that R8 can't resolve, and this
            // app ships no keep rules — so the default release R8 pass fails (missing classes) and
            // would also risk stripping JNI-referenced native classes. Disable shrinking for now so
            // `flutter run --release` builds; revisit with proper proguard keep rules before a real
            // store release (002 on-device verification).
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}

flutter {
    source = "../.."
}
