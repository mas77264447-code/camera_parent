import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.camera_parent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            // الأولوية: key.properties (محلي) ثم متغيرات البيئة (GitHub Actions)
            val storePath = (keystoreProperties["storeFile"] as String?)
                ?: System.getenv("KEYSTORE_PATH")
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = (keystoreProperties["storePassword"] as String?)
                    ?: System.getenv("KEYSTORE_PASSWORD")
                keyAlias = (keystoreProperties["keyAlias"] as String?)
                    ?: System.getenv("KEY_ALIAS")
                keyPassword = (keystoreProperties["keyPassword"] as String?)
                    ?: System.getenv("KEY_PASSWORD")
            }
        }
    }

    defaultConfig {
        applicationId = "com.example.camera_parent"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "role"

    productFlavors {
        create("parent") {
            dimension = "role"
            applicationIdSuffix = ".parent"
            resValue("string", "app_name", "Camera Parent")
        }

        create("child") {
            dimension = "role"
            applicationIdSuffix = ".child"
            resValue("string", "app_name", "Camera")
        }
    }

    buildTypes {
        release {
            val hasReleaseKey = keystorePropertiesFile.exists() ||
                System.getenv("KEYSTORE_PATH") != null
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // بدون مفتاح: توقيع debug (للتجربة فقط، لا توزّعه)
                signingConfigs.getByName("debug")
            }

            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:33.5.0"))
    implementation("com.google.firebase:firebase-messaging")
}

flutter {
    source = "../.."
}
