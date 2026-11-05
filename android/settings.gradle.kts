pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Mapbox (Navigation, Maps, Android Auto) – braucht das Secret Token mit Scope DOWNLOADS:READ
        maven {
            url = uri("https://api.mapbox.com/downloads/v2/releases/maven")
            credentials {
                username = "mapbox"
                password = providers.environmentVariable("MAPBOX_DOWNLOADS_TOKEN")
                    .orElse(providers.gradleProperty("MAPBOX_DOWNLOADS_TOKEN")).getOrElse("")
            }
            authentication { create<BasicAuthentication>("basic") }
        }
    }
}

rootProject.name = "Meeterz"
include(":app")
