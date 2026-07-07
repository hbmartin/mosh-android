# The JNI symbols in libmosh-client.so are bound to org.mosh.MoshClient
# by name; R8 must not rename or strip the class or its native methods.
-keepclasseswithmembers class org.mosh.MoshClient {
    native <methods>;
}
