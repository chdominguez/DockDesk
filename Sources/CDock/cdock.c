#include "cdock.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Private IOKit prototypes, recovered by disassembly on macOS 27.2 (arm64e).
typedef struct __IODPDevice *IODPDeviceRef;
IODPDeviceRef IODPDeviceCreateWithService(CFAllocatorRef alloc, io_service_t service);
IOReturn IODPDeviceReadDPCD(IODPDeviceRef dev, uint32_t addr, void *buf, uint32_t len);
IOReturn IODPDeviceWriteDPCD(IODPDeviceRef dev, uint32_t addr, const void *buf, uint32_t len);

struct td_dock { IODPDeviceRef dev; bool rc_on; bool fw_armed; };

enum { RC_CAP = 0x4B0, RC_CMD = 0x4B2, RC_LEN = 0x4B8, RC_OFFSET = 0x4BC, RC_DATA = 0x4C0 };
enum { CMD_ENABLE_RC = 0x01, CMD_DISABLE_RC = 0x02, CMD_WRITE_MEMORY = 0x21, CMD_READ_FLASH = 0x30, CMD_READ_MEMORY = 0x31 };
enum { RAM_EDID = 0x1600, RAM_CONFIG = 0x1700, RAM_EDID_MODE = 0x1740, RAM_PORTS = 0x1820 };

td_dock *td_open(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPDPDeviceProxy"), &it) != KERN_SUCCESS) return NULL;
    io_service_t s, found = 0;
    while ((s = IOIteratorNext(it))) {
        CFTypeRef loc = IORegistryEntryCreateCFProperty(s, CFSTR("Location"), NULL, 0);
        bool ext = loc && CFGetTypeID(loc) == CFStringGetTypeID() && CFEqual(loc, CFSTR("External"));
        if (loc) CFRelease(loc);
        if (ext && !found) found = s; else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) return NULL;
    IODPDeviceRef dev = IODPDeviceCreateWithService(kCFAllocatorDefault, found);
    IOObjectRelease(found);
    if (!dev) return NULL;
    td_dock *d = calloc(1, sizeof *d);
    d->dev = dev;
    return d;
}

void td_close(td_dock *d) {
    if (!d) return;
    if (d->rc_on) td_rc_disable(d);
    if (d->dev) CFRelease((CFTypeRef)d->dev);
    free(d);
}

int td_dpcd_read(td_dock *d, uint32_t addr, uint8_t *buf, uint32_t len) {
    for (uint32_t off = 0; off < len; off += 16) {
        uint32_t n = len - off > 16 ? 16 : len - off;
        IOReturn r = IODPDeviceReadDPCD(d->dev, addr + off, buf + off, n);
        if (r != kIOReturnSuccess) return (int)r;
    }
    return 0;
}

int td_dpcd_write(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len) {
    for (uint32_t off = 0; off < len; off += 16) {
        uint32_t n = len - off > 16 ? 16 : len - off;
        IOReturn r = IODPDeviceWriteDPCD(d->dev, addr + off, buf + off, n);
        if (r != kIOReturnSuccess) return (int)r;
    }
    return 0;
}

static void le32(uint8_t *b, uint32_t v) { b[0] = v; b[1] = v >> 8; b[2] = v >> 16; b[3] = v >> 24; }

// Only this allow-list of RC commands can ever be sent from this file.
static int rc_exec(td_dock *d, uint8_t cmd) {
    if (cmd != CMD_ENABLE_RC && cmd != CMD_DISABLE_RC && cmd != CMD_READ_MEMORY && cmd != CMD_READ_FLASH && cmd != CMD_WRITE_MEMORY) return -100;
    uint8_t c = cmd | 0x80;
    if (td_dpcd_write(d, RC_CMD, &c, 1)) return -1;
    for (int i = 0; i < 300; i++) {
        uint8_t s[2];
        if (td_dpcd_read(d, RC_CMD, s, 2)) return -1;
        if (!(s[0] & 0x80)) return s[1];
        usleep(10000);
    }
    return -2;
}

int td_rc_disable(td_dock *d) {
    uint8_t z[4] = {0};
    td_dpcd_write(d, RC_LEN, z, 4);
    d->rc_on = false;
    d->fw_armed = false;
    return rc_exec(d, CMD_DISABLE_RC);
}

int td_rc_enable(td_dock *d) {
    uint8_t cap = 0, b[4];
    if (td_dpcd_read(d, RC_CAP, &cap, 1) || !(cap & 0x04)) return -1;
    td_rc_disable(d);
    if (td_dpcd_write(d, RC_DATA, (const uint8_t *)"PRIUS", 5)) return -1;
    le32(b, 0); td_dpcd_write(d, RC_OFFSET, b, 4);
    le32(b, 5); td_dpcd_write(d, RC_LEN, b, 4);
    int r = rc_exec(d, CMD_ENABLE_RC);
    d->rc_on = (r == 0);
    return r;
}

static int rc_read(td_dock *d, uint8_t cmd, uint32_t addr, uint8_t *out, uint32_t len) {
    for (uint32_t off = 0; off < len; off += 32) {
        uint32_t n = len - off > 32 ? 32 : len - off;
        uint8_t b[4];
        le32(b, addr + off); if (td_dpcd_write(d, RC_OFFSET, b, 4)) return -1;
        le32(b, n); if (td_dpcd_write(d, RC_LEN, b, 4)) return -1;
        int r = rc_exec(d, cmd);
        if (r) return r > 0 ? -r - 10 : r;
        if (td_dpcd_read(d, RC_DATA, out + off, n)) return -1;
    }
    return 0;
}

int td_rc_read_memory(td_dock *d, uint32_t addr, uint8_t *out, uint32_t len) { return rc_read(d, CMD_READ_MEMORY, addr, out, len); }
int td_rc_read_flash(td_dock *d, uint32_t addr, uint8_t *out, uint32_t len) { return rc_read(d, CMD_READ_FLASH, addr, out, len); }

int td_get_info(td_dock *d, td_info *info) {
    memset(info, 0, sizeof *info);
    uint8_t b[16], cap = 0;
    if (td_dpcd_read(d, 0x500, b, 13)) return -1;
    memcpy(info->oui, b, 3);
    memcpy(info->device_id, b + 3, 6);
    info->chip_id = (uint16_t)(b[7] << 8 | b[8]);
    memcpy(info->fw, b + 10, 3);
    td_dpcd_read(d, RC_CAP, &cap, 1);
    info->rc_supported = cap & 0x04;
    if (!info->rc_supported || memcmp(info->oui, "\x90\xcc\x24", 3)) return 0;
    if (td_rc_enable(d)) { td_rc_disable(d); return -2; }
    uint8_t cfg[4], p[16], edid[128];
    if (!td_rc_read_memory(d, RAM_CONFIG, cfg, 4) && !memcmp(cfg, "\x20\x00\x83\x83", 4)) {
        info->layout_known = true;
        td_rc_read_memory(d, RAM_EDID_MODE, &info->mode_byte, 1);
        if (!td_rc_read_memory(d, RAM_PORTS, p, 16)) {
            info->monitors = p[1] & 0x0f;
            info->upstream_width = (uint16_t)(p[2] << 8 | p[3]);
            info->port_width = (uint16_t)(p[4] << 8 | p[5]);
            info->splitting = (p[12] | p[13]) != 0;
        }
        if (!td_rc_read_memory(d, RAM_EDID, edid, 128)) {
            for (int o = 54; o <= 108; o += 18) {
                if (!(edid[o] | edid[o + 1])) continue;
                uint16_t w = (uint16_t)(edid[o + 2] | (edid[o + 4] >> 4) << 8), h = (uint16_t)(edid[o + 5] | (edid[o + 7] >> 4) << 8);
                if (w > 2560 && w > info->wide_w) { info->wide_timing = true; info->wide_w = w; info->wide_h = h; }
            }
        }
    }
    td_rc_disable(d);
    return 0;
}

int td_set_edid_mode(td_dock *d, td_edid_mode mode) {
    if (mode != TD_MODE_SPLIT && mode != TD_MODE_MIRROR) return -100;
    if (td_rc_enable(d)) { td_rc_disable(d); return -1; }
    uint8_t cfg[4], cur = 0, back = 0xff, b[4];
    int rc = -3;
    if (!td_rc_read_memory(d, RAM_CONFIG, cfg, 4) && !memcmp(cfg, "\x20\x00\x83\x83", 4) && !td_rc_read_memory(d, RAM_EDID_MODE, &cur, 1)) {
        uint8_t next = (uint8_t)((cur & 0xf0) | mode);
        rc = 0;
        if (next != cur) {
            // The single RAM write this library performs: one byte at 0x1740.
            td_dpcd_write(d, RC_DATA, &next, 1);
            le32(b, RAM_EDID_MODE); td_dpcd_write(d, RC_OFFSET, b, 4);
            le32(b, 1); td_dpcd_write(d, RC_LEN, b, 4);
            rc = rc_exec(d, CMD_WRITE_MEMORY);
            td_rc_read_memory(d, RAM_EDID_MODE, &back, 1);
            if (rc == 0 && back != next) rc = -4;
        }
    }
    td_rc_disable(d);
    return rc;
}

// ---------------------------------------------------------------------------
// Firmware update primitives. A second, separate allow-list: rc_exec() above
// still cannot send checksum, erase or flash-write commands.
// ---------------------------------------------------------------------------
enum { CMD_CAL_CHECKSUM = 0x11, CMD_FLASH_ERASE = 0x14, CMD_CAL_CRC16 = 0x17, CMD_WRITE_FLASH = 0x20 };
enum { REG_BOOT_STATUS = 0x20010C, REG_MCU_CMD = 0x2000FC, REG_QUAD = 0x200FC0, REG_HDCP22 = 0x200F90 };

static int rc_exec_fw(td_dock *d, uint8_t cmd, int timeout_ms) {
    bool ro = cmd == CMD_CAL_CHECKSUM || cmd == CMD_CAL_CRC16;
    bool rw = cmd == CMD_FLASH_ERASE || cmd == CMD_WRITE_FLASH || cmd == CMD_WRITE_MEMORY;
    if (!ro && !rw) return -100;
    if (!d->rc_on) return -101;
    if (rw && !d->fw_armed) return -102;
    uint8_t c = cmd | 0x80;
    if (td_dpcd_write(d, RC_CMD, &c, 1)) return -1;
    for (int waited = 0; waited <= timeout_ms; waited += 5) {
        uint8_t s[2];
        if (td_dpcd_read(d, RC_CMD, s, 2)) return -1;
        if (!(s[0] & 0x80)) return s[1];
        usleep(5000);
    }
    return -2;
}

static int rc_args(td_dock *d, uint32_t addr, uint32_t len) {
    uint8_t b[4];
    le32(b, addr); if (td_dpcd_write(d, RC_OFFSET, b, 4)) return -1;
    le32(b, len); if (td_dpcd_write(d, RC_LEN, b, 4)) return -1;
    return 0;
}

static int rc_calc(td_dock *d, uint8_t cmd, uint32_t addr, uint32_t len, uint32_t *out) {
    if (!len || addr > 0x80000 || len > 0x80000 - addr) return -100;
    if (rc_args(d, addr, len)) return -1;
    int r = rc_exec_fw(d, cmd, 15000);
    if (r) return r > 0 ? -r - 10 : r;
    uint8_t b[4];
    if (td_dpcd_read(d, RC_DATA, b, 4)) return -1;
    *out = b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
    return 0;
}
int td_rc_checksum(td_dock *d, uint32_t a, uint32_t l, uint32_t *s) { return rc_calc(d, CMD_CAL_CHECKSUM, a, l, s); }
int td_rc_crc16(td_dock *d, uint32_t a, uint32_t l, uint32_t *c) { return rc_calc(d, CMD_CAL_CRC16, a, l, c); }

int td_fw_arm(td_dock *d, uint32_t magic) {
    if (!d->rc_on || magic != TD_FW_ARM_MAGIC) return -102;
    d->fw_armed = true;
    return 0;
}

// Which bank the hub booted from, asked from the hub itself before every destructive command.
static int running_bank(td_dock *d) {
    uint8_t b[4];
    if (td_rc_read_memory(d, REG_BOOT_STATUS, b, 4)) return -1;
    uint32_t s = b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
    return (s & (1u << 7)) || (s & (1u << 30)) ? 1 : 0;
}

int td_fw_write_memory(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len) {
    if (len != 4) return -100;
    if (addr == REG_MCU_CMD) {
        if (!((buf[0] == 0x21 || buf[0] == 0xF5) && !buf[1] && !buf[2] && !buf[3])) return -100;
    } else if (addr != REG_QUAD && addr != REG_HDCP22) return -100;
    if (!d->fw_armed) return -102;
    if (td_dpcd_write(d, RC_DATA, buf, 4) || rc_args(d, addr, 4)) return -1;
    int r = rc_exec_fw(d, CMD_WRITE_MEMORY, 3000);
    return r > 0 ? -r - 10 : r;
}

int td_fw_erase(td_dock *d, uint16_t code) {
    if (!d->fw_armed) return -102;
    int rb = running_bank(d);
    if (rb < 0) return -1;
    bool ok64 = code >= 0x3000 && code <= 0x3003 && (code & 0xF) / 2 != rb; // inactive bank only
    bool okTag = code == (rb ? 0x103F : 0x101F);                             // running bank's tag sector
    if (!ok64 && !okTag) return -100;
    uint8_t b[2] = {(uint8_t)code, (uint8_t)(code >> 8)};
    if (td_dpcd_write(d, RC_DATA, b, 2) || rc_args(d, 0, 2)) return -1;
    int r = rc_exec_fw(d, CMD_FLASH_ERASE, 15000);
    return r > 0 ? -r - 10 : r;
}

int td_fw_write_flash(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len) {
    if (!d->fw_armed) return -102;
    if (!len || len > 32 || addr / 32 != (addr + len - 1) / 32 || addr + len > 0x40000) return -100;
    int rb = running_bank(d);
    if (rb < 0 || addr / 0x20000 == (uint32_t)rb) return -100;
    if (td_dpcd_write(d, RC_DATA, buf, len) || rc_args(d, addr, len)) return -1;
    int r = rc_exec_fw(d, CMD_WRITE_FLASH, 3000);
    return r > 0 ? -r - 10 : r;
}
