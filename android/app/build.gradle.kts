import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("org.jetbrains.kotlin.plugin.compose")
}

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.isFile) {
        file.inputStream().use(::load)
    }
}

fun localPropertyOrEnv(name: String): String? =
    localProperties.getProperty(name) ?: System.getenv(name)

val buildArm64Split = providers.gradleProperty("cardbal.abiSplit")
    .map { it.equals("true", ignoreCase = true) }
    .getOrElse(false)

val appVersionName = providers.gradleProperty("transitic.versionName").orElse("0.1.1").get()
require(appVersionName.isNotBlank() && appVersionName == appVersionName.trim() &&
    appVersionName.none { it.isISOControl() }) {
    "transitic.versionName must be a nonempty version without surrounding whitespace or control characters"
}
val appVersionCodeText = providers.gradleProperty("transitic.versionCode").orElse("4").get()
val appVersionCode = appVersionCodeText.toIntOrNull()
require(appVersionCode != null && appVersionCode in 1..2_100_000_000 &&
    appVersionCodeText.matches(Regex("[0-9]+"))) {
    "transitic.versionCode must be an integer between 1 and 2100000000"
}

val stationAssetsDirectory = layout.buildDirectory.dir("generated/stationAssets")
val portableStationDirectory = layout.buildDirectory.dir("generated/portableStationAssets")

android {
    namespace = "ad.neko.cardbal.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "ad.neko.cardbal.android"
        minSdk = 26
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersionName
    }

    splits {
        abi {
            isEnable = buildArm64Split
            reset()
            include("arm64-v8a")
            isUniversalApk = false
        }
    }

    signingConfigs {
        create("release") {
            val storePath = localPropertyOrEnv("CARDBAL_UPLOAD_STORE_FILE")
            if (!storePath.isNullOrBlank()) {
                storeFile = rootProject.file(storePath)
                storePassword = localPropertyOrEnv("CARDBAL_UPLOAD_STORE_PASSWORD")
                keyAlias = localPropertyOrEnv("CARDBAL_UPLOAD_KEY_ALIAS")
                keyPassword = localPropertyOrEnv("CARDBAL_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val releaseSigningConfig = signingConfigs.getByName("release")
            if (releaseSigningConfig.storeFile != null) {
                signingConfig = releaseSigningConfig
            }
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    sourceSets.getByName("main").assets.setSrcDirs(listOf(stationAssetsDirectory))
    sourceSets.getByName("test").resources.srcDir("../../tests/runtime/fixtures")

    lint {
        disable += "NullSafeMutableLiveData"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.material3:material3:1.4.0")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("org.maplibre.gl:android-sdk:12.3.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.1")

    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
}

val prepareStationAssets by tasks.registering(Exec::class) {
    val repositoryRoot = rootProject.projectDir.parentFile
    val python = providers.gradleProperty("transitic.python").orElse("python3")
    val sourceOverride = providers.environmentVariable("CARDBAL_STATIONS_SOURCE").orElse("")
    workingDir(repositoryRoot)
    inputs.files(fileTree(repositoryRoot) {
        include("data/stations/**", "data/boundaries/**")
        include("scripts/**/*.py", "scripts/**/*.json", "tools/**/*.py", "tools/**/*.json")
        exclude("**/__pycache__/**", "**/build/**", "**/dist/**", "**/.git/**")
    })
    inputs.property("stationSourceOverride", sourceOverride)
    // An explicit contribution checkout may change without changing the pin.
    outputs.upToDateWhen { sourceOverride.get().isBlank() }
    outputs.dir(stationAssetsDirectory)
    outputs.dir(portableStationDirectory)
    commandLine(python.get(), "scripts/build_cross_platform_station_assets.py",
        "--source", "csv", "--target", "all", "--no-sync-ios",
        "--android-assets", stationAssetsDirectory.get().asFile.absolutePath,
        "--portable-assets", portableStationDirectory.get().asFile.absolutePath)
    doLast {
        val required = setOf("JPStationCodes.csv", "JPBusCodes.csv", "jp_stations.sqlite",
            "tunion_stations.sqlite", "cardbal_transit.sqlite", "KOTRISTransportModes.json", "manifest.json")
        required.forEach { name ->
            check(stationAssetsDirectory.get().file(name).asFile.isFile) {
                "Shared station build did not produce the required Android asset: $name"
            }
        }
        val directory = stationAssetsDirectory.get().asFile
        val actual = directory.walkTopDown().filter { it.isFile }
            .map { it.relativeTo(directory).invariantSeparatorsPath }.toSet()
        check(actual == required) {
            "Android station assets must contain only consumed files; unexpected: ${actual - required}"
        }
    }
}

tasks.named("preBuild") {
    dependsOn(prepareStationAssets)
}
