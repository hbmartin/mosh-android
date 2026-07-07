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

import android.content.Context
import java.io.File
import java.io.IOException
import java.util.zip.ZipInputStream

/**
 * Installs the terminfo database bundled with the AAR (as the asset
 * `terminfo.zip`) into app-private storage so the mosh client can read
 * it via the `TERMINFO` environment variable.
 */
object Terminfo {
    private const val ASSET_NAME = "terminfo.zip"

    /**
     * Extracts the bundled terminfo database if it is not installed yet
     * and returns the directory to use as the `TERMINFO` environment
     * variable (i.e. the directory containing entries like `x/xterm-256color`).
     *
     * Idempotent and versioned: each library/mosh version extracts into
     * its own directory, so upgrades never see a stale database.  Safe to
     * call from any process, but do the first call off the main thread.
     */
    @JvmStatic
    fun install(context: Context): File {
        val installRoot = File(
            context.filesDir,
            "mosh/terminfo/${BuildConfig.MOSH_VERSION}-${BuildConfig.LIBRARY_VERSION}"
        )
        // Zip entries are share/terminfo/<initial>/<name>.
        val terminfoDir = File(installRoot, "share/terminfo")
        val marker = File(installRoot, ".ok")
        if (marker.isFile && terminfoDir.isDirectory) {
            return terminfoDir
        }

        installRoot.deleteRecursively()
        installRoot.mkdirs()
        val rootPath = installRoot.canonicalFile
        val rootPrefix = rootPath.path + File.separator

        context.assets.open(ASSET_NAME).use { asset ->
            ZipInputStream(asset.buffered()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    val target = File(rootPath, entry.name)
                    // Guard against zip-slip: every entry must stay under installRoot.
                    if (!target.canonicalPath.startsWith(rootPrefix)) {
                        throw IOException("terminfo.zip entry escapes install dir: ${entry.name}")
                    }
                    if (entry.isDirectory) {
                        target.mkdirs()
                    } else {
                        target.parentFile?.mkdirs()
                        target.outputStream().use { zip.copyTo(it) }
                    }
                    zip.closeEntry()
                }
            }
        }

        if (!terminfoDir.isDirectory) {
            throw IOException("terminfo.zip did not contain share/terminfo")
        }
        marker.createNewFile()
        return terminfoDir
    }
}
