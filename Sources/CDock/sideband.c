// DisplayPort MST sideband messages to the hub itself (LCT 1), sent over AUX while the
// hub stays in single-stream mode. Message layout and CRCs follow DisplayPort 1.2 and
// Linux drm_dp_mst_topology.c. Only an allow-list of requests can be sent from here.
#include "cdock.h"
#include <string.h>
#include <unistd.h>

enum { MSTM_CTRL = 0x111, DOWN_REQ = 0x1000, DOWN_REP = 0x1400, IRQ_VECTOR = 0x201, IRQ_ESI0 = 0x2003, DOWN_REP_RDY = 0x10 };
enum { REQ_LINK_ADDRESS = 0x01, REQ_REMOTE_DPCD_WRITE = 0x21, REQ_REMOTE_I2C_WRITE = 0x23, REQ_POWER_UP_PHY = 0x24, REQ_POWER_DOWN_PHY = 0x25 };

static uint8_t crc_bits(const uint8_t *data, int bits, int width, uint16_t poly) {
    uint16_t top = (uint16_t)(1u << width), rem = 0;
    for (int i = 0; i < bits; i++) {
        rem = (uint16_t)(rem << 1 | ((data[i / 8] >> (7 - i % 8)) & 1));
        if (rem & top) rem ^= poly;
    }
    for (int i = 0; i < width; i++) {
        rem <<= 1;
        if (rem & top) rem ^= poly;
    }
    return (uint8_t)(rem & (top - 1));
}

int td_sb_begin(td_dock *d) {
    uint8_t v = 0x06, ack = DOWN_REP_RDY; // UP_REQ_EN | UPSTREAM_IS_SRC, MST_EN stays 0
    td_dpcd_write(d, IRQ_ESI0, &ack, 1);  // drop any stale reply
    return td_dpcd_write(d, MSTM_CTRL, &v, 1);
}

int td_sb_end(td_dock *d) {
    uint8_t v = 0;
    return td_dpcd_write(d, MSTM_CTRL, &v, 1);
}

// Sends one request body and collects the reply body. Returns the reply length,
// <0 on transport errors, -20 - reason if the hub answered NAK.
static int sb_request(td_dock *d, const uint8_t *body, int len, uint8_t *reply, int cap) {
    uint8_t type = body[0] & 0x7f;
    if (type != REQ_LINK_ADDRESS && type != REQ_REMOTE_DPCD_WRITE && type != REQ_REMOTE_I2C_WRITE && type != REQ_POWER_UP_PHY && type != REQ_POWER_DOWN_PHY) return -100;
    if (len < 1 || len > 44) return -100;
    uint8_t msg[48];
    bool path = type == REQ_POWER_UP_PHY || type == REQ_POWER_DOWN_PHY;
    msg[0] = 0x10;                                       // LCT 1, LCR 0
    msg[1] = (uint8_t)((path ? 0x40 : 0) | (len + 1));   // body length includes its CRC
    msg[2] = 0xC0;                                       // SOMT | EOMT, sequence 0
    msg[2] |= crc_bits(msg, 20, 4, 0x13);
    memcpy(msg + 3, body, (size_t)len);
    msg[3 + len] = crc_bits(body, len * 8, 8, 0xd5);
    if (td_dpcd_write(d, DOWN_REQ, msg, (uint32_t)len + 4)) return -1;

    int got = 0;
    for (;;) {
        uint8_t irq = 0, hdr[3], chunk[48], ack = DOWN_REP_RDY;
        int waited = 0;
        for (; waited < 3000; waited += 10) {
            if (td_dpcd_read(d, IRQ_ESI0, &irq, 1)) return -1;
            if (irq & DOWN_REP_RDY) break;
            usleep(10000);
        }
        if (!(irq & DOWN_REP_RDY)) return -2;
        if (td_dpcd_read(d, DOWN_REP, hdr, 3)) return -1;
        int n = hdr[1] & 0x3f;
        if ((hdr[0] >> 4) != 1 || n < 1 || n > 45) return -3;
        if (td_dpcd_read(d, DOWN_REP + 3, chunk, (uint32_t)n)) return -1;
        td_dpcd_write(d, IRQ_ESI0, &ack, 1);
        td_dpcd_write(d, IRQ_VECTOR, &ack, 1);
        if (crc_bits(chunk, (n - 1) * 8, 8, 0xd5) != chunk[n - 1]) return -4;
        if (got + n - 1 > cap) return -5;
        memcpy(reply + got, chunk, (size_t)n - 1);
        got += n - 1;
        if (hdr[2] & 0x40) break; // EOMT
    }
    if (got < 1 || (reply[0] & 0x7f) != type) return -6;
    if (reply[0] & 0x80) return -20 - (got > 17 ? reply[17] : 0);
    return got;
}

int td_sb_link_address(td_dock *d, uint8_t *reply, int cap) {
    uint8_t body[1] = {REQ_LINK_ADDRESS};
    return sb_request(d, body, 1, reply, cap);
}

int td_sb_power_phy(td_dock *d, uint8_t port, bool up) {
    if (port < 1 || port > 3) return -100; // output ports only
    uint8_t body[2] = {up ? REQ_POWER_UP_PHY : REQ_POWER_DOWN_PHY, (uint8_t)(port << 4)}, reply[64];
    int r = sb_request(d, body, 2, reply, sizeof reply);
    return r < 0 ? r : 0;
}

int td_sb_remote_set_power(td_dock *d, uint8_t port, uint8_t state) {
    if (port < 1 || port > 3 || (state != 1 && state != 2)) return -100; // DPCD 0x600 of the monitor: D0 or D3 only
    uint8_t body[6] = {REQ_REMOTE_DPCD_WRITE, (uint8_t)(port << 4), 0x06, 0x00, 1, state}, reply[64];
    int r = sb_request(d, body, 6, reply, sizeof reply);
    return r < 0 ? r : 0;
}

// DDC/CI "set VCP 0xD6 (power mode)" to the monitor behind one output: 1 = on, 4 = standby, 5 = off.
int td_sb_ddc_power(td_dock *d, uint8_t port, uint8_t mode) {
    if (port < 1 || port > 3 || (mode < 1 || mode > 5)) return -100;
    uint8_t ddc[7] = {0x51, 0x84, 0x03, 0xD6, 0x00, mode, 0x6E};
    for (int i = 0; i < 6; i++) ddc[6] ^= ddc[i];
    uint8_t body[11] = {REQ_REMOTE_I2C_WRITE, (uint8_t)(port << 4), 0x37, 7}, reply[64];
    memcpy(body + 4, ddc, 7);
    int r = sb_request(d, body, 11, reply, sizeof reply);
    return r < 0 ? r : 0;
}

int td_soft_unplug(td_dock *d) {
    if (td_sb_begin(d)) return -1;
    int r = td_sb_ddc_power(d, 1, 5);
    if (r) r = td_sb_ddc_power(d, 2, 5);
    td_sb_end(d);
    return r;
}
