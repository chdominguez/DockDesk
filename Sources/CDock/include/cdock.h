// CDock: talk to a Synaptics VMM "Panamera" MST hub (Dell WD19 family) from macOS
// over the DisplayPort AUX channel, using Apple's private IODPDevice user client
// and Synaptics' "remote control" (RC) vendor protocol (as in fwupd's synaptics-mst).
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct td_dock td_dock;

// Open the external DisplayPort branch device. NULL if none / access refused.
td_dock *td_open(void);
void td_close(td_dock *d);

// Raw DPCD access (chunked to 16-byte AUX transactions). 0 on success.
int td_dpcd_read(td_dock *d, uint32_t addr, uint8_t *buf, uint32_t len);
int td_dpcd_write(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len);

// Synaptics RC session. Read-only commands plus one allow-listed RAM write.
int td_rc_enable(td_dock *d);
int td_rc_disable(td_dock *d);
int td_rc_read_memory(td_dock *d, uint32_t addr, uint8_t *out, uint32_t len);
int td_rc_read_flash(td_dock *d, uint32_t addr, uint8_t *out, uint32_t len);

// Read-only RC computations: the hub sums its own flash, nothing is modified.
int td_rc_checksum(td_dock *d, uint32_t addr, uint32_t len, uint32_t *sum); // RC 0x11, byte sum
int td_rc_crc16(td_dock *d, uint32_t addr, uint32_t len, uint32_t *crc);    // RC 0x17

// ---- firmware update primitives (separate allow-list; see docs/flasher.md) ----
// Every td_fw_* call returns -102 unless td_fw_arm() was called in the current RC
// session. td_rc_disable() and td_close() disarm.
#define TD_FW_ARM_MAGIC 0x5331F1A5u
int td_fw_arm(td_dock *d, uint32_t magic);
// 4 bytes to 0x2000FC (only 21 00 00 00 or F5 00 00 00), 0x200FC0 or 0x200F90.
int td_fw_write_memory(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len);
// Only 0x3000..0x3003 (64K sectors of the INACTIVE bank) and the RUNNING bank's tag sector (0x101F / 0x103F).
int td_fw_erase(td_dock *d, uint16_t code);
// 1..32 bytes, no 32-byte boundary crossing, below 0x40000, never inside the running bank.
int td_fw_write_flash(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len);

typedef enum { TD_MODE_AGGREGATE_SYNA = 0, TD_MODE_SPLIT = 2, TD_MODE_MIRROR = 3, TD_MODE_KEEP = 4 } td_edid_mode;

typedef struct {
    uint8_t oui[3];
    char device_id[7];       // e.g. "SYNAS1"
    uint16_t chip_id;        // 0x5331 for VMM5331
    uint8_t fw[3];           // e.g. 5,7,4
    bool rc_supported;
    bool layout_known;       // config block signature 20 00 83 83 found at RAM 0x1700
    uint8_t mode_byte;       // RAM 0x1740
    uint8_t monitors;        // low nibble of RAM 0x1821
    uint16_t upstream_width; // RAM 0x1822 (valid on firmware with ViewXpand)
    uint16_t port_width;     // RAM 0x1824
    bool splitting;          // RAM 0x182C word != 0
    bool wide_timing;        // upstream EDID offers a timing wider than 2560
    uint16_t wide_w, wide_h;
} td_info;

// Fills `info`. Returns 0 on success, <0 if the hub cannot be queried.
int td_get_info(td_dock *d, td_info *info);

// Set the low nibble of RAM 0x1740 (volatile). Only TD_MODE_SPLIT / TD_MODE_MIRROR accepted.
int td_set_edid_mode(td_dock *d, td_edid_mode mode);

// --- display modes (private CoreGraphics services, as used by displayplacer) ---
// Switch `display` to a native (1x) mode of w x h, picking the highest refresh <= max_hz.
// Returns 0 on success, 1 if no such mode exists.
int td_set_native_mode(uint32_t display, uint32_t w, uint32_t h, uint32_t max_hz);

void td_dump_modes(uint32_t display);
