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

    In addition, as a special exception, the copyright holders give
    permission to link the code of portions of this program with the
    OpenSSL library under certain conditions as described in each
    individual source file, and distribute linked combinations including
    the two.

    You must obey the GNU General Public License in all respects for all
    of the code used other than OpenSSL. If you modify file(s) with this
    exception, you may extend this exception to your version of the
    file(s), but you are not obligated to do so. If you do not wish to do
    so, delete this exception statement from your version. If you delete
    this exception statement from all source files in the program, then
    also delete it here.
*/

/* JNI entry points for running the mosh client from an Android app.

   The Java-side contract (see android/README.md) is:

     package org.mosh;

     public final class MoshClient {
       static { System.loadLibrary("mosh-client"); }

       // Returns mosh-client's exit status.  args are the arguments that
       // would follow "mosh-client" on a command line; env entries are
       // "NAME=VALUE" strings (MOSH_KEY, TERM, TERMINFO, ...).  The fds
       // (usually a pty slave) are dup2()ed onto stdin/stdout/stderr of
       // the *whole process* before the client runs; pass -1 to leave a
       // descriptor untouched.
       public static native int nativeMoshClientMain(
           String[] args, String[] env,
           int stdinFd, int stdoutFd, int stderrFd);

       // Raise SIGWINCH in this process so the client re-reads the
       // window size after the app resizes the pty.
       public static native void nativeNotifyWindowSizeChanged();
     }

   Because the client takes over stdin/stdout, installs process-wide
   signal handlers, and may call exit() on fatal errors, it must run in
   a dedicated app process (android:process=":mosh"), not in the main
   app process. */

#include "src/include/config.h"

#ifdef MOSH_ANDROID_JNI

#include <csignal>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <getopt.h>
#include <jni.h>
#include <unistd.h>

extern "C" int mosh_client_main( int argc, char* argv[] );

static std::vector<std::string> string_array( JNIEnv* env, jobjectArray array )
{
  std::vector<std::string> out;
  if ( array == NULL ) {
    return out;
  }

  const jsize len = env->GetArrayLength( array );
  for ( jsize i = 0; i < len; i++ ) {
    jstring jstr = static_cast<jstring>( env->GetObjectArrayElement( array, i ) );
    if ( jstr == NULL ) {
      continue;
    }
    const char* chars = env->GetStringUTFChars( jstr, NULL );
    if ( chars != NULL ) {
      out.push_back( std::string( chars ) );
      env->ReleaseStringUTFChars( jstr, chars );
    }
    env->DeleteLocalRef( jstr );
  }
  return out;
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad( JavaVM* vm __attribute__( ( unused ) ),
                                              void* reserved __attribute__( ( unused ) ) )
{
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jint JNICALL Java_org_mosh_MoshClient_nativeMoshClientMain( JNIEnv* env,
                                                                                 jclass clazz
                                                                                 __attribute__( ( unused ) ),
                                                                                 jobjectArray jargs,
                                                                                 jobjectArray jenv,
                                                                                 jint stdin_fd,
                                                                                 jint stdout_fd,
                                                                                 jint stderr_fd )
{
  /* Export "NAME=VALUE" entries into the process environment. */
  const std::vector<std::string> env_entries = string_array( env, jenv );
  for ( std::vector<std::string>::const_iterator it = env_entries.begin(); it != env_entries.end(); ++it ) {
    const std::string::size_type eq = it->find( '=' );
    if ( eq == std::string::npos || eq == 0 ) {
      continue;
    }
    setenv( it->substr( 0, eq ).c_str(), it->substr( eq + 1 ).c_str(), 1 );
  }

  /* Attach the supplied descriptors (normally a pty slave) to the
     process's stdin/stdout/stderr. */
  if ( stdin_fd >= 0 && dup2( stdin_fd, STDIN_FILENO ) < 0 ) {
    perror( "dup2(stdin)" );
    return 255;
  }
  if ( stdout_fd >= 0 && dup2( stdout_fd, STDOUT_FILENO ) < 0 ) {
    perror( "dup2(stdout)" );
    return 255;
  }
  if ( stderr_fd >= 0 && dup2( stderr_fd, STDERR_FILENO ) < 0 ) {
    perror( "dup2(stderr)" );
    return 255;
  }

  std::vector<std::string> args_storage = string_array( env, jargs );
  args_storage.insert( args_storage.begin(), std::string( "mosh-client" ) );

  std::vector<char*> argv;
  for ( std::vector<std::string>::iterator it = args_storage.begin(); it != args_storage.end(); ++it ) {
    argv.push_back( const_cast<char*>( it->c_str() ) );
  }
  argv.push_back( NULL );

  /* Reset getopt state in case the client runs more than once in this
     process. */
#ifdef __ANDROID__
  optreset = 1;
#endif
  optind = 1;

  return mosh_client_main( static_cast<int>( argv.size() ) - 1, argv.data() );
}

extern "C" JNIEXPORT void JNICALL Java_org_mosh_MoshClient_nativeNotifyWindowSizeChanged(
  JNIEnv* env __attribute__( ( unused ) ),
  jclass clazz __attribute__( ( unused ) ) )
{
  raise( SIGWINCH );
}

#endif /* MOSH_ANDROID_JNI */
