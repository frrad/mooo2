/*
 * loadprobe.dll — minimal injection probe for the "Spike A" check described in
 * docs/inject-spike.md and docs/driving.md §5 (the DESIGN.md §13.1 follow-on).
 *
 * It answers exactly one question: can an injected DLL be loaded into the boxed
 * client's process under Wine at all? On DLL_PROCESS_ATTACH it records one line
 * ("I was loaded, into THIS process") and returns TRUE so the host process
 * continues normally. It touches no client internals, hooks nothing, and
 * contains no offsets or proprietary data — this is our own, implementation-
 * neutral tooling (DESIGN.md §11).
 *
 * Pure Win32 only (no CRT) to keep the injected surface tiny: the probe must be
 * able to fail to load for interesting reasons (override not honored, anti-tamper,
 * crash), not because of a missing runtime.
 */
#include <windows.h>

static void record_load(void)
{
    /* Marker path is a *Windows* path; default lives on C: so the harness can
     * read it at $WINEPREFIX/drive_c/loadprobe.log. */
    char marker[MAX_PATH];
    if (!GetEnvironmentVariableA("KAKAO_LOADPROBE_MARKER", marker, sizeof(marker)))
        lstrcpynA(marker, "C:\\loadprobe.log", sizeof(marker));

    /* Full path of the *host* process, so the harness can confirm the probe
     * loaded into KakaoTalk.exe specifically and not just some Wine helper. */
    char host[MAX_PATH] = {0};
    GetModuleFileNameA(NULL, host, sizeof(host));

    char line[2 * MAX_PATH];
    int n = wsprintfA(line, "loaded pid=%lu host=%s\r\n",
                      (unsigned long)GetCurrentProcessId(), host);
    if (n <= 0)
        return;

    HANDLE h = CreateFileA(marker, FILE_APPEND_DATA,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return;

    DWORD written = 0;
    WriteFile(h, line, (DWORD)n, &written, NULL);
    CloseHandle(h);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)inst;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
        record_load();
    return TRUE;
}
