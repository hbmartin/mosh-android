# Android JNI Assets

This branch builds the mosh client as a JNI shared library that Android
apps can load directly, instead of a standalone executable.

The `android-jni-release-assets` GitHub Actions workflow (or a local run
of `android/build-android-jni-assets.sh` with an Android NDK installed)
produces one archive per ABI:

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

## Java-side contract

`libmosh-client.so` exports JNI methods for this class (include it in
your app verbatim — the package and class name must match):

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
  a directory where you extracted `terminfo.zip` (it unpacks to
  `share/terminfo/...`).
- **Locale.** The client is hard-wired to UTF-8 on Android; no locale
  environment variables are needed.

## Licensing

These assets are GPL-licensed as part of mosh. Apps that consume them
should present that license fact before downloading or enabling the
library.
