/*
 * seize-probe.exe: a tiny Windows program, run under Wine by verify-seize.sh, that
 * reads every clock and CSPRNG API the client could use and prints one
 * "name value" line each. Two runs with the same seize inputs must print the
 * same random bytes and a clock at the pinned date. Our own code; it does not
 * touch the client (DESIGN §11).
 *
 * "seize-probe.exe chain" checks instead that the seized clock is one clock for
 * the whole process tree, including processes started after the first seized one
 * has exited. It prints its wall and QPC clocks in milliseconds ("parent_*"),
 * starts "seize-probe.exe relay" and exits at once. The relay sleeps, prints its
 * clocks ("relay_*"), then starts "seize-probe.exe child", which prints its own
 * ("child_*"). On one clock the child reads no earlier than the relay; a child
 * whose clock restarted at the pinned instant reads earlier.
 */
#define _CRT_RAND_S
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <rpc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

#define RELAY_SLEEP_MS 2000

static void clocks_ms(const char *who)
{
    FILETIME ft;
    LARGE_INTEGER qpc, qpf;
    ULARGE_INTEGER t;

    GetSystemTimePreciseAsFileTime(&ft);
    t.LowPart = ft.dwLowDateTime;
    t.HighPart = ft.dwHighDateTime;
    QueryPerformanceCounter(&qpc);
    QueryPerformanceFrequency(&qpf);
    /* FILETIME counts 100 ns ticks since 1601; print Unix milliseconds. */
    printf("%s_wall_ms %llu\n", who, (t.QuadPart - 116444736000000000ULL) / 10000);
    printf("%s_qpc_ms %lld\n", who,
           qpc.QuadPart / (qpf.QuadPart >= 1000 ? qpf.QuadPart / 1000 : 1));
    fflush(stdout);
}

/* Start "<this exe> <mode>"; wait for it to exit if wait is set. */
static BOOL spawn(const char *mode, BOOL wait)
{
    char self[MAX_PATH], cmd[MAX_PATH + 16];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;

    GetModuleFileNameA(NULL, self, sizeof(self));
    snprintf(cmd, sizeof(cmd), "\"%s\" %s", self, mode);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        printf("%s unavailable\n", mode);
        return FALSE;
    }
    if (wait) WaitForSingleObject(pi.hProcess, 60000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return TRUE;
}

int main(int argc, char **argv)
{
    unsigned char b[N];
    FILETIME ft;
    SYSTEMTIME st;
    LARGE_INTEGER qpc, qpf;

    if (argc > 1 && strcmp(argv[1], "chain") == 0) {
        clocks_ms("parent");
        return spawn("relay", FALSE) ? 0 : 1;           /* exit before the child */
    }
    if (argc > 1 && strcmp(argv[1], "relay") == 0) {
        Sleep(RELAY_SLEEP_MS);
        clocks_ms("relay");
        return spawn("child", TRUE) ? 0 : 1;
    }
    if (argc > 1 && strcmp(argv[1], "child") == 0) {
        clocks_ms("child");
        return 0;
    }

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
