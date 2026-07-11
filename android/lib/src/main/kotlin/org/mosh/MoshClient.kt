/*
    Mosh: the mobile shell
    Copyright 2012 Keith Winstein

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

package org.mosh

/**
 * JNI binding for the mosh client in `libmosh-client.so`.
 *
 * The native side (src/frontend/mosh_jni.cc) binds to this exact class:
 * the symbols are `Java_org_mosh_MoshClient_*`, so the package, class
 * name, and method signatures here are load-bearing.  The natives are
 * declared `static` (jclass) in C++, which is why they are `@JvmStatic`
 * members of a named object rather than a companion object (a companion
 * would mangle the symbols to `..._00024Companion_*`).
 *
 * Runtime contract — the client must run in a **dedicated app process**
 * (e.g. a Service with `android:process=":mosh"`), never in the main app
 * process, because it:
 *  - `dup2()`s the supplied fds over the whole process's stdin/stdout/stderr,
 *  - installs process-wide signal handlers, and
 *  - may call `exit()` on fatal errors.
 *
 * Typical use from the `:mosh` process:
 * ```
 * val terminfo = Terminfo.install(context)
 * val env = MoshEnvironment.build(moshKey = key, terminfoDir = terminfo)
 * val status = MoshClient.nativeMoshClientMain(
 *     arrayOf(host, port), env, ptySlaveFd, ptySlaveFd, ptySlaveFd)
 * ```
 */
object MoshClient {
    init {
        System.loadLibrary("mosh-client")
    }

    /**
     * Runs the mosh client and returns its exit status.
     *
     * @param args the arguments that would follow `mosh-client` on a
     *   command line, typically `[host, port]`.
     * @param env `"NAME=VALUE"` entries exported into the process
     *   environment before the client starts; must include at least
     *   `MOSH_KEY`, `TERM`, and `TERMINFO` (see [MoshEnvironment.build]).
     * @param stdinFd,stdoutFd,stderrFd descriptors (usually a pty slave)
     *   `dup2()`ed onto the process's stdin/stdout/stderr before the
     *   client runs; pass -1 to leave a descriptor untouched.
     */
    @JvmStatic
    external fun nativeMoshClientMain(
        args: Array<String>,
        env: Array<String>,
        stdinFd: Int,
        stdoutFd: Int,
        stderrFd: Int,
    ): Int

    /**
     * Raises SIGWINCH in this process so the client re-reads the window
     * size.  Call after resizing the pty with `TIOCSWINSZ`.
     */
    @JvmStatic
    external fun nativeNotifyWindowSizeChanged()
}
