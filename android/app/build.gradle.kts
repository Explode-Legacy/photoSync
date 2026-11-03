import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.photobridge.photobridge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.photobridge.photobridge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release key: on GitHub from secrets (PB_KEYSTORE + PB_KEYSTORE_PASSWORD),
    // on the developer's Mac from ~/.android/photobridge-release.properties.
    // Without either, builds fall back to the debug key.
    val releaseKey: Map<String, String>? = run {
        System.getenv("PB_KEYSTORE")?.takeIf { file(it).exists() }?.let { path ->
            val pass = System.getenv("PB_KEYSTORE_PASSWORD") ?: return@let null
            mapOf("storeFile" to path, "storePassword" to pass, "keyAlias" to "photobridge", "keyPassword" to pass)
        } ?: File(System.getProperty("user.home"), ".android/photobridge-release.properties")
            .takeIf { it.exists() }
            ?.let { f ->
                Properties().apply { f.inputStream().use { load(it) } }
                    .let { props -> props.stringPropertyNames().associateWith { props.getProperty(it) } }
            }
    }
    signingConfigs {
        if (releaseKey != null) {
            create("release") {
                storeFile = file(releaseKey.getValue("storeFile"))
                storePassword = releaseKey.getValue("storePassword")
                keyAlias = releaseKey.getValue("keyAlias")
                keyPassword = releaseKey.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKey != null) "release" else "debug")
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
