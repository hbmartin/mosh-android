AM_CPPFLAGS = -I$(top_srcdir)/ $(TINFO_CFLAGS) $(protobuf_CFLAGS) $(CRYPTO_CFLAGS)
AM_CXXFLAGS = $(WARNING_CXXFLAGS) $(PICKY_CXXFLAGS) $(HARDEN_CFLAGS) $(MISC_CXXFLAGS) $(CODE_COVERAGE_CXXFLAGS)
AM_LDFLAGS  = $(HARDEN_LDFLAGS) $(CODE_COVERAGE_LIBS)
LDADD = ../crypto/libmoshcrypto.a ../network/libmoshnetwork.a ../statesync/libmoshstatesync.a ../terminal/libmoshterminal.a ../util/libmoshutil.a ../protobufs/libmoshprotos.a -lm $(TINFO_LIBS) $(protobuf_LIBS) $(CRYPTO_LIBS)

mosh_server_LDADD = $(LDADD)

bin_PROGRAMS =

if BUILD_CLIENT
  bin_PROGRAMS += mosh-client
endif

if BUILD_SERVER
  bin_PROGRAMS += mosh-server
endif

if BUILD_ANDROID_JNI
  bin_PROGRAMS += libmosh-client.so
endif

mosh_client_SOURCES = mosh-client.cc stmclient.cc stmclient.h terminaloverlay.cc terminaloverlay.h
mosh_server_SOURCES = mosh-server.cc

# libmosh-client.so is the mosh client built as an Android JNI library.
# It is linked as a "program" with -shared; -pie from HARDEN_LDFLAGS must
# not reach this link, so AM_LDFLAGS is deliberately not used here.
libmosh_client_so_SOURCES = $(mosh_client_SOURCES) mosh_jni.cc
libmosh_client_so_CPPFLAGS = $(AM_CPPFLAGS) -DMOSH_ANDROID_JNI
libmosh_client_so_CXXFLAGS = $(AM_CXXFLAGS) -fPIC
libmosh_client_so_LDFLAGS = $(CODE_COVERAGE_LIBS) -shared -Wl,-z,relro -Wl,-z,now
libmosh_client_so_LDADD = $(LDADD)
