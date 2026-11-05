plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

/** Wert aus Umgebung (CI) oder ~/.gradle/gradle.properties / local.properties */
fun config(name: String): String =
    providers.environmentVariable(name).orElse(providers.gradleProperty(name)).getOrElse("")

val navVersion = "3.32.3"

android {
    namespace = "de.koeven.meeterz"
    compileSdk = 36

    defaultConfig {
        applicationId = "de.koeven.meeterz"
        minSdk = 26
        targetSdk = 36
        versionCode = (providers.environmentVariable("BUILD_NUMBER").orNull ?: "1").toInt()
        versionName = "1.0"

        buildConfigField("String", "SUPABASE_URL", "\"https://jgtkyxlzroajtxboqgcn.supabase.co\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${config("SUPABASE_ANON_KEY")}\"")
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${config("GOOGLE_WEB_CLIENT_ID")}\"")
        resValue("string", "mapbox_access_token", config("MAPBOX_PUBLIC_TOKEN"))
    }

    signingConfigs {
        // Fester Schlüssel aus den Repo-Secrets – Google-Login prüft den SHA-1 der Signatur
        val keystore = config("ANDROID_KEYSTORE_FILE")
        if (keystore.isNotEmpty()) {
            create("meeterz") {
                storeFile = file(keystore)
                storePassword = config("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = "meeterz"
                keyPassword = config("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            signingConfigs.findByName("meeterz")?.let { signingConfig = it }
        }
        release {
            isMinifyEnabled = false
            signingConfigs.findByName("meeterz")?.let { signingConfig = it }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    // Mapbox: Navigation (wie auf iOS), Karte und Android Auto
    implementation("com.mapbox.navigationcore:navigation:$navVersion")
    implementation("com.mapbox.navigationcore:ui-maps:$navVersion")
    implementation("com.mapbox.navigationcore:android-auto-components:$navVersion")
    implementation("androidx.car.app:app:1.7.0")

    // Supabase (gleiches Backend wie iOS)
    implementation(platform("io.github.jan-tennert.supabase:bom:3.8.0"))
    implementation("io.github.jan-tennert.supabase:auth-kt")
    implementation("io.github.jan-tennert.supabase:postgrest-kt")
    implementation("io.github.jan-tennert.supabase:realtime-kt")
    implementation("io.github.jan-tennert.supabase:functions-kt")
    implementation("io.ktor:ktor-client-okhttp:3.5.1")

    // Mit Google anmelden
    implementation("androidx.credentials:credentials:1.5.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.5.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    // Oberfläche
    implementation(platform("androidx.compose:compose-bom:2025.05.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")

    testImplementation("junit:junit:4.13.2")
}
