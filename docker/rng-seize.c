/*
 * RNG seize for the Wine-boxed reference client (Tier 1, DESIGN §5.1 / §9).
 *
 * Every Windows CSPRNG the client can reach (BCryptGenRandom, RtlGenRandom /
 * SystemFunction036, CryptGenRandom, rand_s, ProcessPrng, UUID generation) ends
 * up in Wine's unix-side ntdll.so, which asks the host kernel via getrandom().
 * This LD_PRELOAD library replaces that one host call for the whole Wine process
 * tree, so the Windows address space -- and the client's protector -- never sees
 * a change. It works below the Windows modules, like libfaketime does for time.
 *
 * Environment:
 *   MOOO_RNG_SEED  64-bit seed (hex or decimal). Unset: the shim passes through
 *                  to the real getrandom and only logs (record-only).
 *   MOOO_RNG_LOG   directory; each process appends every byte it was served to
 *                  <dir>/<exe>.<pid>.rng (the captured entropy stream).
 *
 * With a seed, each process gets its own stream: block i of process P is
 * splitmix64(seed ^ fnv1a(P's exe name) + i). The stream is deliberately NOT
 * cryptographic: the point is that we chose, and can reproduce, every random
 * byte the client used. Replay = same seed. Only ever use a seeded box with a
 * disposable account (DESIGN §11).
 *
 * Limits: one counter per process, so concurrent threads draw in scheduling
 * order; the stream is keyed by exe name only (same-name instances share it); a
 * fork without exec repeats the parent's stream; the key is read from argv[0] at
 * the first draw, so a draw before Wine rewrites argv is keyed as the loader.
 * Out of reach: randomness the client makes without asking the OS (RDRAND /
 * RDSEED instructions, timing jitter). See docs/boxing.md.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

static int seeded = -1;          /* -1 = not initialised yet */
static uint64_t seed, key;
static uint64_t pos;             /* bytes served so far (atomic) */
static int log_fd = -1;

static uint64_t splitmix64(uint64_t x)
{
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

/* The process's own exe name, lowercased: the last path component of argv[0],
 * splitting on both '/' and '\' (Wine processes carry their Windows path). */
static void exe_name(char *out, size_t n)
{
    char buf[4096];
    ssize_t r = -1;
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        r = read(fd, buf, sizeof(buf) - 1);
        close(fd);
    }
    if (r <= 0) {
        snprintf(out, n, "unknown");
        return;
    }
    buf[r] = 0;
    const char *b = buf;
    for (const char *p = buf; *p; p++)
        if (*p == '/' || *p == '\\')
            b = p + 1;
    size_t i = 0;
    for (; b[i] && i + 1 < n; i++) {
        char c = b[i];
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        out[i] = (c == '/' || c == ' ') ? '_' : c;
    }
    out[i] = 0;
}

static void init(void)
{
    if (__atomic_load_n(&seeded, __ATOMIC_ACQUIRE) >= 0)
        return;
    char name[256];
    exe_name(name, sizeof(name));
    uint64_t h = 0xcbf29ce484222325ULL;   /* FNV-1a */
    for (const char *p = name; *p; p++)
        h = (h ^ (unsigned char)*p) * 0x100000001b3ULL;
    key = h;

    const char *s = getenv("MOOO_RNG_SEED");
    int on = 0;
    if (s && *s) {
        seed = strtoull(s, NULL, 0);
        on = 1;
    }
    const char *dir = getenv("MOOO_RNG_LOG");
    if (dir && *dir) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s.%d.rng", dir, name, (int)getpid());
        log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    }
    __atomic_store_n(&seeded, on, __ATOMIC_RELEASE);
}

static ssize_t (*real_getrandom)(void *, size_t, unsigned);

static ssize_t serve(void *buf, size_t len, unsigned flags)
{
    init();
    ssize_t r;
    if (seeded) {
        uint64_t start = __atomic_fetch_add(&pos, len, __ATOMIC_RELAXED);
        unsigned char *out = buf;
        for (size_t i = 0; i < len; i++) {
            uint64_t at = start + i;
            uint64_t block = splitmix64((seed ^ key) + at / 8);
            out[i] = (unsigned char)(block >> (8 * (at % 8)));
        }
        r = (ssize_t)len;
    } else {
        if (!real_getrandom)
            real_getrandom = dlsym(RTLD_NEXT, "getrandom");
        if (real_getrandom) {
            r = real_getrandom(buf, len, flags);
        } else {   /* not via syscall(): that is interposed below */
            int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
            r = fd >= 0 ? read(fd, buf, len) : -1;
            if (fd >= 0)
                close(fd);
        }
    }
    if (r > 0 && log_fd >= 0) {
        ssize_t w = write(log_fd, buf, (size_t)r);
        (void)w;
    }
    return r;
}

ssize_t getrandom(void *buf, size_t len, unsigned flags)
{
    return serve(buf, len, flags);
}

int getentropy(void *buf, size_t len)
{
    if (len > 256) {
        errno = EIO;
        return -1;
    }
    return serve(buf, len, 0) == (ssize_t)len ? 0 : -1;
}

/* Some code calls the syscall directly; catch that too and pass the rest on. */
long syscall(long n, ...)
{
    static long (*real_syscall)(long, ...);
    va_list ap;
    va_start(ap, n);
    long a1 = va_arg(ap, long), a2 = va_arg(ap, long), a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long), a5 = va_arg(ap, long), a6 = va_arg(ap, long);
    va_end(ap);
    if (n == SYS_getrandom)
        return serve((void *)a1, (size_t)a2, (unsigned)a3);
    if (!real_syscall)
        real_syscall = dlsym(RTLD_NEXT, "syscall");
    return real_syscall(n, a1, a2, a3, a4, a5, a6);
}
