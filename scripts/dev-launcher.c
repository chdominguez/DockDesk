// Development launcher. macOS ties the Screen Recording permission of an
// ad-hoc signed app to the exact binary, so a rebuilt app loses it. This tiny
// launcher never changes: it loads the freshly built app code from a library
// placed next to the .app bundle and starts it.
#include <dlfcn.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char exe[4096], real[4096], lib[4200];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) || !realpath(exe, real)) return 1;
    // <dir>/TwinDesk Dev.app/Contents/MacOS/TwinDesk -> <dir>/libTwinDeskDev.dylib
    char *dir = dirname(dirname(dirname(dirname(real))));
    snprintf(lib, sizeof lib, "%s/libTwinDeskDev.dylib", dir);
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "TwinDesk dev launcher: %s\n", dlerror()); return 1; }
    void (*entry)(void) = (void (*)(void))dlsym(h, "twindesk_main");
    if (!entry) { fprintf(stderr, "TwinDesk dev launcher: entry point missing\n"); return 1; }
    entry();
    return 0;
}
