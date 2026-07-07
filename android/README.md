# mosh for Android

This branch builds the mosh client as a JNI shared library that Android
apps can load directly, instead of a standalone executable, and packages
it as an Android library (AAR) published to Maven Central.

> **⚠️ Licensing:** mosh — and therefore this AAR — is licensed under the
> **GNU GPL v3.0 or later**. An app that links against this library must
> be distributed under a GPL-compatible license, with corresponding
> source available. This is a hard constraint for closed-source apps.
> See [`COPYING`](../COPYING).

## Use from Gradle

```kotlin
dependencies {
    implementation("io.github.hbmartin:mosh-android:0.1.0")
}
```

The AAR bundles `libmosh-client.so` for `arm64-v8a`, `armeabi-v7a`,
`x86`, and `x86_64` (minSdk 24), the terminfo database as an asset, and
a small Kotlin API in the `org.mosh` package:

- `MoshClient` — the JNI binding (`nativeMoshClientMain`,
  `nativeNotifyWindowSizeChanged`)
- `Terminfo.install(context)` — extracts the bundled terminfo database
  into app-private storage and returns the directory to use as `TERMINFO`
- `MoshEnvironment.build(moshKey, terminfoDir, term, extra)` — builds the
  `"NAME=VALUE"` environment array the client requires

Typical usage, from a `Service` running in a dedicated `:mosh` process
(see [Runtime requirements](#runtime-requirements) for why):

```kotlin
val terminfo = Terminfo.install(context)          // off the main thread
val env = MoshEnvironment.build(
    moshKey = keyFromMoshServerHandshake,
    terminfoDir = terminfo,
)
val exitStatus = MoshClient.nativeMoshClientMain(
    arrayOf(serverHost, serverPort),
    env,
    ptySlaveFd, ptySlaveFd, ptySlaveFd,
)
```

The app still owns the `mosh-server` handshake (usually over ssh), the
pty pair, and the terminal emulator view.

## Raw release assets

If you don't want the AAR, the `android-jni-release-assets` GitHub
Actions workflow (or a local run of `android/build-android-jni-assets.sh`
with an Android NDK installed) produces one archive per ABI:

- `mosh-android-jni-arm64-v8a.zip`
- `mosh-android-jni-armeabi-v7a.zip`
- `mosh-android-jni-x86.zip`
- `mosh-android-jni-x86_64.zip`

Each archive contains:

- `jniLibs/<abi>/libmosh-client.so`, the mosh client built as a JNI
  library (drop into your module's `src/main/jniLibs/`)
- `terminfo.zip`, the terminfo database the client needs at runtime

The libraries are self-contained: libc++, protobuf, nettle, gmp, zlib
and ncurses/tinfo are statically linked; the only shared dependencies
are Android system libraries (`libc`, `libm`, `libdl`, `liblog`). They
are built with 16 KB page-size compatible alignment.

When consuming the raw zips, include this class in your app verbatim
(the `.so` binds to it by name — package and class name must match):

```java
package org.mosh;

public final class MoshClient {
    static {
        System.loadLibrary("mosh-client");
    }

    /**
     * Runs the mosh client and returns its exit status.
     *
     * @param args arguments as they would follow "mosh-client" on a
     *             command line, e.g. {"-#", "user@host", "203.0.113.5", "60001"}
     * @param env  "NAME=VALUE" strings exported into the process
     *             environment before the client starts (MOSH_KEY, TERM,
     *             TERMINFO, MOSH_PREDICTION_DISPLAY, ...)
     * @param stdinFd/stdoutFd/stderrFd descriptors (normally a pty
     *             slave) dup2()ed onto fds 0/1/2 of the whole process;
     *             pass -1 to leave a descriptor untouched
     */
    public static native int nativeMoshClientMain(
            String[] args, String[] env,
            int stdinFd, int stdoutFd, int stderrFd);

    /** Raise SIGWINCH so the client re-reads the pty window size. */
    public static native void nativeNotifyWindowSizeChanged();
}
```

If you prefer your own class name, write a small JNI shim of your own
and call the exported C symbol `mosh_client_main(int argc, char** argv)`
instead.

## Runtime requirements

- **Run in a dedicated process.** The client takes over the process's
  stdin/stdout, installs process-wide signal handlers (SIGWINCH,
  SIGTERM, ...), and calls `exit()` on fatal errors. Host it in an
  Android `Service` with `android:process=":mosh"` so it cannot take
  down your app.
- **PTY plumbing.** Create a pty pair (e.g. `Os.posix_openpt`-style via
  your own JNI or `ParcelFileDescriptor.createSocketPair` alternatives),
  hand the slave fd to `nativeMoshClientMain`, and connect the master to
  your terminal emulator view. After resizing the pty (`TIOCSWINSZ` on
  the master), call `nativeNotifyWindowSizeChanged()`.
- **Environment.** At minimum pass `MOSH_KEY` (from the `mosh-server`
  handshake), `TERM` (e.g. `xterm-256color`), and `TERMINFO` pointing at
  the terminfo database (`Terminfo.install` handles this when using the
  AAR; with raw zips, extract `terminfo.zip` yourself — it unpacks to
  `share/terminfo/...`).
- **Locale.** The client is hard-wired to UTF-8 on Android; no locale
  environment variables are needed.

## Building and releasing the AAR

The Gradle project lives in [`android/`](.) (`:lib` module). It does not
compile the native code itself; it imports the per-ABI zips produced by
`android/build-android-jni-assets.sh`:

```sh
./android/build-android-jni-assets.sh   # needs an Android NDK
cd android
./gradlew :lib:assembleRelease          # AAR in lib/build/outputs/aar/
```

The script wipes `build/android-jni/` at startup unless `KEEP_WORK_DIR=1`
is set; set it (optionally with `ABIS="..."`) for incremental rebuilds
that reuse the already-built dependency prefixes and keep the other
ABIs' zips.

Releases are cut by pushing a tag `android-jni-v<version>` where
`<version>` matches `VERSION_NAME` in `android/gradle.properties`. CI
builds the native libraries with a pinned NDK, assembles and validates
the AAR, publishes `io.github.hbmartin:mosh-android` to Maven Central,
and attaches the raw zips and the AAR to the GitHub release. A
`-SNAPSHOT` can be published via the workflow's manual dispatch with
`snapshot=true`.

Publishing needs these repository secrets (used by the
`com.vanniktech.maven.publish` plugin):

- `MAVEN_CENTRAL_USERNAME` / `MAVEN_CENTRAL_PASSWORD` — a
  [Central Portal](https://central.sonatype.com) user token for an
  account that owns the `io.github.hbmartin` namespace
- `SIGNING_KEY` — an armored GPG secret key
  (`gpg --export-secret-keys --armor <KEYID>`) whose public half is on
  `keyserver.ubuntu.com`
- `SIGNING_KEY_PASSWORD` — its passphrase

## Licensing

These assets are GPL-licensed (GPL-3.0-or-later) as part of mosh. Apps
that consume them must comply with the GPL, and should present that
license fact before downloading or enabling the library.
