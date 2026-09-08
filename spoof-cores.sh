# 1. Create the source file
sudo tee /usr/local/lib/spoof_cores.c > /dev/null << 'EOF'
#define _GNU_SOURCE
#include <unistd.h>
#include <dlfcn.h>

#define SPOOFED_CORES 8

/* Intercept sysconf without triggering malloc/dlsym during critical init */
long sysconf(int name) {
    if (name == _SC_NPROCESSORS_ONLN || name == _SC_NPROCESSORS_CONF) {
        return SPOOFED_CORES;
    }
    
    static long (*real_sysconf)(int) = NULL;
    if (!real_sysconf) {
        real_sysconf = (long (*)(int))dlsym(RTLD_NEXT, "sysconf");
    }
    return real_sysconf(name);
}
EOF

# 2. Compile into a shared library
sudo gcc -O2 -fPIC -shared /usr/local/lib/spoof_cores.c -o /usr/local/lib/libspoof_cores.so -ldl

# 3. Ensure proper permissions
sudo chmod 0755 /usr/local/lib/libspoof_cores.so
sudo chmod 0644 /usr/local/lib/spoof_cores.c