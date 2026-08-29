plugins { id("com.android.application") }

val copySyncBaseUrl = providers.gradleProperty("COPYSYNC_BASE_URL")
    .orElse("https://copy.example.com")
    .get()
    .trimEnd('/') + "/"

android {
    namespace = "xyz.copyweb"
    compileSdk = 35

    defaultConfig {
        applicationId = "xyz.copyweb"
        minSdk = 26
        targetSdk = 35
        versionCode = 24
        versionName = "1.23"
        buildConfigField("String", "COPYSYNC_BASE_URL", "\"$copySyncBaseUrl\"")
    }
    buildFeatures {
        buildConfig = true
    }
}
