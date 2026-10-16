/*
 * seize-probe.exe: a tiny Windows program, run under Wine by verify-seize.sh, that
 * reads every clock and CSPRNG API the client could use and prints one
 * "name value" line each. Two runs with the same seize inputs must print the
 * same random bytes and a clock at the pinned date. Our own code; it does not
 * touch the client (DESIGN §11).
 */
#define _CRT_RAND_S
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <rpc.h>
#include <stdio.h>
#include <stdlib.h>

#define N 16

static void hex(const char *name, const unsigned char *b, int n, BOOL ok)
{
    printf("%s ", name);
    if (!ok) { printf("unavailable\n"); return; }
    for (int i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

typedef BOOLEAN (WINAPI *rtlgenrandom_fn)(PVOID, ULONG);
typedef BOOL (WINAPI *processprng_fn)(PBYTE, SIZE_T);

int main(void)
{
    unsigned char b[N];
    FILETIME ft;
    SYSTEMTIME st;
    LARGE_INTEGER qpc, qpf;

    GetSystemTimeAsFileTime(&ft);
    FileTimeToSystemTime(&ft, &st);
    printf("systime %04u-%02u-%02uT%02u:%02u:%02u\n", st.wYear, st.wMonth, st.wDay,
           st.wHour, st.wMinute, st.wSecond);
    GetSystemTimePreciseAsFileTime(&ft);
    FileTimeToSystemTime(&ft, &st);
    printf("systime_precise %04u-%02u-%02u\n", st.wYear, st.wMonth, st.wDay);
    GetLocalTime(&st);
    printf("localtime %04u-%02u-%02u\n", st.wYear, st.wMonth, st.wDay);
    QueryPerformanceCounter(&qpc);
    QueryPerformanceFrequency(&qpf);
    printf("qpc_seconds %lld\n", qpc.QuadPart / (qpf.QuadPart ? qpf.QuadPart : 1));
    printf("tick_seconds %llu\n", GetTickCount64() / 1000);

    hex("bcrypt_genrandom", b, N,
        BCRYPT_SUCCESS(BCryptGenRandom(NULL, b, N, BCRYPT_USE_SYSTEM_PREFERRED_RNG)));

    HMODULE adv = LoadLibraryA("advapi32.dll");
    rtlgenrandom_fn rgr = (rtlgenrandom_fn)GetProcAddress(adv, "SystemFunction036");
    hex("rtlgenrandom", b, N, rgr && rgr(b, N));

    HCRYPTPROV prov;
    BOOL ok = CryptAcquireContextA(&prov, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT);
    hex("cryptgenrandom", b, N, ok && CryptGenRandom(prov, N, b));
    if (ok) CryptReleaseContext(prov, 0);

    HMODULE prim = LoadLibraryA("bcryptprimitives.dll");
    processprng_fn pp = prim ? (processprng_fn)GetProcAddress(prim, "ProcessPrng") : NULL;
    hex("processprng", b, N, pp && pp(b, N));

    unsigned int r[N / 4];
    ok = TRUE;
    for (int i = 0; i < N / 4; i++) ok = ok && rand_s(&r[i]) == 0;
    hex("rand_s", (unsigned char *)r, N, ok);

    UUID u;
    hex("uuidcreate", (unsigned char *)&u, sizeof(u), UuidCreate(&u) == RPC_S_OK);
    return 0;
}
