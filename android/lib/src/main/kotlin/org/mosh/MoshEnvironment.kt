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

import java.io.File

/**
 * Builds the `"NAME=VALUE"` environment entries that
 * [MoshClient.nativeMoshClientMain] requires.
 */
object MoshEnvironment {
    /**
     * @param moshKey the session key printed by `mosh-server new` (the
     *   `MOSH CONNECT <port> <key>` line).  Treat it as a secret.
     * @param terminfoDir the directory returned by [Terminfo.install].
     * @param term terminal type to advertise; the bundled database
     *   includes `xterm-256color` and friends.
     * @param extra additional variables, e.g. `MOSH_PREDICTION_DISPLAY`.
     */
    @JvmStatic
    @JvmOverloads
    fun build(
        moshKey: String,
        terminfoDir: File,
        term: String = "xterm-256color",
        extra: Map<String, String> = emptyMap(),
    ): Array<String> {
        require(moshKey.isNotBlank()) { "moshKey must not be blank" }
        val env = linkedMapOf(
            "MOSH_KEY" to moshKey,
            "TERM" to term,
            "TERMINFO" to terminfoDir.absolutePath,
        )
        env.putAll(extra)
        return env.map { (name, value) -> "$name=$value" }.toTypedArray()
    }
}
