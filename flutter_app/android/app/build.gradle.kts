import java.util.Properties
import java.io.FileInputStream

// BATCH-02 (F-W3-013): release keystore 基础设施。
// 若 flutter_app/android/key.properties 存在，加载其中的签名信息；
// 否则保持 hasReleaseKeystore = false，buildTypes.release 会 fallback
// 到 debug keystore 并在控制台 println 警告。模板见 key.properties.example。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.legado.app.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // BuildConfig is required at runtime for SSRF blacklist's DEBUG-bypass:
    // debug builds are allowed to hit loopback/RFC1918 (so the local
    // api-server is reachable from the same device), release builds aren't.
    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "io.legado.app.flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只编译 arm64-v8a，缩小 APK 体积、加快构建。
        // 当前主流真机均为 arm64，如需兼容 32 位 ARM 或 x86 模拟器，
        // 把对应 ABI 加回此列表，并在 build_android_debug.sh 里补 cross-compile target。
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
            // 若 key.properties 不存在，本 config 保持 unconfigured；
            // buildTypes.release 下方会做条件 fallback。
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                println("⚠️  flutter_app/android/key.properties 不存在；release 仍用 debug keystore 签名（不可上架，也无法做受信升级）")
                println("    生成 release keystore 见 flutter_app/android/key.properties.example")
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
