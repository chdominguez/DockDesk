// Native (1x) display mode selection. The public CGDisplayMode API hides the
// non-HiDPI variant of wide modes, so use the CoreGraphics services calls
// that tools like displayplacer rely on.
#include "cdock.h"
#include <ApplicationServices/ApplicationServices.h>

typedef union {
    uint8_t raw[0xDC];
    struct {
        uint32_t mode, flags, width, height, depth;
        uint32_t pad[42];
        uint16_t pad2, freq;
        uint8_t pad3[16];
        float density;
    } d;
} td_cgs_mode;

void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *n);
void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx, td_cgs_mode *mode, int length);
void CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int mode);

int td_set_native_mode(uint32_t display, uint32_t w, uint32_t h, uint32_t max_hz) {
    int n = 0, best = -1;
    uint16_t best_hz = 0;
    CGSGetNumberOfDisplayModes(display, &n);
    for (int i = 0; i < n; i++) {
        td_cgs_mode m;
        CGSGetDisplayModeDescriptionOfLength(display, i, &m, sizeof m);
        if (m.d.width != w || m.d.height != h || m.d.density != 1.0f) continue;
        if (m.d.freq > max_hz || m.d.freq < best_hz) continue;
        best = (int)m.d.mode; best_hz = m.d.freq;
    }
    if (best < 0) return 1;
    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg)) return 2;
    CGSConfigureDisplayMode(cfg, display, best);
    return CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently) ? 3 : 0;
}

// Debug helper: print the modes wider than 2000 px.
#include <stdio.h>
void td_dump_modes(uint32_t display) {
    int n = 0;
    CGSGetNumberOfDisplayModes(display, &n);
    for (int i = 0; i < n; i++) {
        td_cgs_mode m;
        CGSGetDisplayModeDescriptionOfLength(display, i, &m, sizeof m);
        if (m.d.width >= 1900) printf("mode %d: %ux%u depth %u freq %u density %.2f flags 0x%x\n", i, m.d.width, m.d.height, m.d.depth, m.d.freq, m.d.density, m.d.flags);
    }
}
