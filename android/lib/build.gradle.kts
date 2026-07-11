import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import org.gradle.kotlin.dsl.support.serviceOf
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

// Version of mosh embedded in libmosh-client.so (configure.ac AC_INIT).
val moshVersion = "1.4.0"

android {
    namespace = "org.mosh"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "MOSH_VERSION", "\"$moshVersion\"")
        buildConfigField("String", "LIBRARY_VERSION", "\"${property("VERSION_NAME")}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    packaging {
        // Keep .so files uncompressed and page-aligned in the APK so they
        // can be mmapped directly; libmosh-client.so is linked with
        // -Wl,-z,max-page-size=16384 for 16 KB page devices.
        jniLibs.useLegacyPackaging = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

// libmosh-client.so and terminfo.zip are produced by
// android/build-android-jni-assets.sh as one zip per ABI under
// build/android-jni/ (repo root).  Import them into the AAR instead of
// checking binaries into the source tree.
val nativeAssetZipsDir = rootDir.resolve("../build/android-jni")
val abiZips = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
    .associateWith { nativeAssetZipsDir.resolve("mosh-android-jni-$it.zip") }

val importNativeAssets by tasks.registering(Sync::class) {
    description = "Unpacks the per-ABI zips built by android/build-android-jni-assets.sh"

    // Capture only configuration-cache-serializable values (files and the
    // ArchiveOperations service) in the closures below, not the script object.
    val archives = serviceOf<ArchiveOperations>()
    val zips = abiZips.values.toList()

    doFirst {
        val missing = zips.filterNot(File::exists)
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Missing native asset zips:\n" + missing.joinToString("\n") { "  $it" } +
                    "\nRun android/build-android-jni-assets.sh first."
            )
        }
    }

    zips.forEach { zip ->
        // Wrap zipTree in a lazy provider so configuration does not fail
        // while the zips have not been built yet.
        from({ zip.takeIf(File::exists)?.let(archives::zipTree) ?: emptyList<File>() }) {
            include("jniLibs/**")
        }
    }
    // terminfo.zip is ABI-independent; take the arm64-v8a copy.
    val arm64Zip = abiZips.getValue("arm64-v8a")
    from({ arm64Zip.takeIf(File::exists)?.let(archives::zipTree) ?: emptyList<File>() }) {
        include("terminfo.zip")
        into("assets")
    }

    into(layout.buildDirectory.dir("importedNativeAssets"))
}

android.sourceSets["main"].jniLibs.srcDir(layout.buildDirectory.dir("importedNativeAssets/jniLibs"))
android.sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("importedNativeAssets/assets"))

tasks.named("preBuild") {
    dependsOn(importNativeAssets)
}

mavenPublishing {
    publishToMavenCentral(automaticRelease = true)
    // Sign when a key is provided (CI sets ORG_GRADLE_PROJECT_signingInMemoryKey);
    // local publishToMavenLocal runs stay unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }

    configure(AndroidSingleVariantLibrary("release", sourcesJar = true, publishJavadocJar = true))

    coordinates("io.github.hbmartin", "mosh-android", property("VERSION_NAME") as String)

    pom {
        name.set("mosh-android")
        description.set("Mosh (mobile shell) client $moshVersion as an Android JNI library")
        url.set("https://github.com/hbmartin/mosh-android")
        licenses {
            license {
                name.set("GPL-3.0-or-later")
                url.set("https://www.gnu.org/licenses/gpl-3.0.txt")
            }
        }
        developers {
            developer {
                id.set("hbmartin")
                name.set("Harold Martin")
                email.set("harold.martin@gmail.com")
            }
        }
        scm {
            url.set("https://github.com/hbmartin/mosh-android")
            connection.set("scm:git:git://github.com/hbmartin/mosh-android.git")
            developerConnection.set("scm:git:ssh://git@github.com/hbmartin/mosh-android.git")
        }
    }
}
