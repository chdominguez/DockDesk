# VMM5331 hub firmware: backup, verification and flashing from macOS

Status: **offline only**. Everything below was derived from fwupd source, Dell's packages and a real
512 KiB dump of this dock. Nothing in `Sources/FirmwareKit` has ever sent a write to real hardware,
and the CDock primitives it needs for that do not exist yet (proposed in section 9).

Sources used (all treated as reference data):

* fwupd **2.0.20**, `plugins/synaptics-mst/fu-synaptics-mst-device.c`, `fu-synaptics-mst-common.c`,
  `fu-synaptics-mst-firmware.c`, `fu-synaptics-mst.rs`, `synaptics-mst.quirk`
* fwupd **2.0.20**, `plugins/dell-dock/fu-dell-dock-mst.c`, `fu-dell-dock-ec.c`, `fu-dell-dock-hid.c`,
  `fu-dell-dock-common.c`, `fu-dell-dock.rs`, `dell-dock.quirk`, `fu-dell-dock-plugin.c`
* Dell packages `DellDockFirmwareUpdateLinux_01.00.{06,08,09,16,20,28,31}.cab`,
  `WD19FirmwareUpdateLinux_01.00.{04,14,15}.cab` (hub images extracted with `/usr/bin/tar`)
* `~/mst-probe/fwdump/flash_0_40000.bin` + `flash_40000_80000.bin` (dock running 05.07.08)

FirmwareKit derives its procedure and constants from fwupd, so its files carry
`SPDX-License-Identifier: LGPL-2.1-or-later`.

---

## 1. What the flash looks like (verified on 10 Dell images and the dump)

512 KiB SPI flash:

| Range | Content |
|---|---|
| `0x00000-0x1FFFF` | bank 0 (128 KiB) |
| `0x20000-0x3FFFF` | bank 1 (128 KiB) |
| `0x40000-0x7FFFF` | ESM (HDCP 2.2 "embedded security module" code) |

Per bank (offsets relative to the bank start):

| Offset | Content | Evidence |
|---|---|---|
| `0x000` | fallback EDID (`00 FF FF FF FF FF FF 00`) | all images |
| `0x100-0x1FF` | config block, starts `20 00 83 83`, byte sum of the 256 bytes is 0 mod 256 | all images; RAM `0x1700` mirrors it on the live hub (`ram_0_2000_mode3.bin`) |
| `0x10E-0x10F` | customer id / board id, u16 BE = `01 03` (Dell / WD19) | all images; fwupd `ADDR_CUSTOMER_ID_TESLA 0x10E`; dell-dock instance id `MST-panamera-vmm5331-259` (259 = 0x0103) |
| `0x400` | u32 BE code size; code ends at value + `0x410` = `0x18406` in every image | fwupd `fw_size += 0x410` |
| `0x18400-0x18402` | version bytes (`05 07 04`) | dell-dock quirk `DellDockBlobMajorOffset = 0x18400`; matches DPCD `0x50A` of the running bank in the dump |
| `0x62F` | version again, but only in 05.07.x (05.06.03 and older have `00 21 08` there) | so FirmwareKit uses `0x18400` |
| `0x18406-0x1FFEF` | `00` padding in Dell images | all images |
| `0x1FFF0-0x1FFFF` | bank tag | see below |

Bank tag (16 bytes), as written by fwupd synaptics-mst:

```c
buf[0] = helper->bank_to_update;
buf[1] = g_date_time_get_month(dt);
buf[2] = g_date_time_get_day_of_month(dt);
buf[3] = g_date_time_get_year(dt) - 2000;
buf[4] = (helper->checksum >> 8) & 0xff;   /* CRC-16 of the 0x1A000 written bytes */
buf[5] = helper->checksum & 0xff;
buf[15] = fu_synaptics_mst_calculate_crc8(0, buf, sizeof(buf) - 1);
```

What Dell ships: every `vmm5331.bin` contains **both bank halves, byte-identical except the tag**,
each half carrying its own tag (`00 0c 0d 17 4a 51 00.. 64` for bank 0 and `01 0c 0d 17 4a 51 00.. 82`
for bank 1 in 01.00.20). Bytes 4..5 are the constant `4a 51` in **all 10 images** (05.03.10 to
05.07.08); they are not a CRC-16 of the content (checked by brute force over all prefix lengths: only
random hits). CRC-8 (poly 0xD5, init 0) of bytes 0..14 equals byte 15 in every tag.

The ESM region is identical in all 05.06.03-05.07.08 images (byte sum `0x01e4639e`) and in the dump;
05.03.10-05.04.06 have a different ESM (`0x01c97260`).

The dump (05.07.08 running): bank 1 is byte-identical to the bank-1 half of 01.00.31; bank 0 is the
bank-0 half of 01.00.20 (05.07.04) **with its last 4 KiB sector erased** (tag all FF). That is the
footprint of the dell-dock invalidation (section 3, step D7) from the earlier 05.07.04 -> 05.07.08
update. ESM equals every 05.06+ image.

Version bytes: dell-dock prints them as hex (`%02x.%02x.%02x`), which is how Dell/LVFS name releases;
synaptics-mst prints decimal. They differ only for bytes >= 10 (01.00.04 is bytes `05 03 10` = "05.03.10").
FirmwareKit compares raw bytes and prints hex.

## 2. fwupd synaptics-mst (DPCD RC transport)

### 2.1 RC mailbox (DPCD)

| Register | Address | Use |
|---|---|---|
| RC_CAP | `0x4B0` | bit 2 = RC supported |
| RC_CMD | `0x4B2` | write `cmd | 0x80`; busy while bit 7 set |
| RC_RESULT | `0x4B3` | result code (0 ok, 1 invalid, 2 unsupported, 3 failed, 4 disabled, ...) |
| RC_LEN | `0x4B8` | u32 LE |
| RC_OFFSET | `0x4BC` | u32 LE |
| RC_DATA | `0x4C0` | up to 32 bytes |

* `rc_set_command` (writes): per 32-byte chunk (`UNIT_SIZE 32`): write data to RC_DATA, offset to
  RC_OFFSET, length to RC_LEN, then `cmd | 0x80` to RC_CMD, then poll RC_CMD/RC_RESULT (2 bytes) up to
  30 times with 100 ms between tries (`fu_device_retry_full(..., 30, 100, ...)`). With no data, only the
  command is sent.
* `rc_get_command` (reads): per 32-byte chunk: offset, length, command, poll, read RC_DATA.
* `rc_special_get_command` (checksums): offset, length (no data), command, poll, read 4 bytes LE from RC_DATA.
* Enable: DISABLE_RC first, then ENABLE_RC (0x01) with data `"PRIUS"` (5 bytes). CDock already does this.

Command codes (`fu-synaptics-mst.rs`): ENABLE_RC 0x01, DISABLE_RC 0x02, CAL_EEPROM_CHECKSUM 0x11,
FLASH_ERASE 0x14, CAL_EEPROM_CHECK_CRC16 0x17, ACTIVATE_FIRMWARE 0x18 (Cayenne/Carrera only),
WRITE_TO_EEPROM 0x20, WRITE_TO_MEMORY 0x21, READ_FROM_EEPROM 0x30, READ_FROM_MEMORY 0x31.

### 2.2 Panamera write, in order (`fu_synaptics_mst_device_write_firmware`)

| # | Step | Exact traffic |
|---|---|---|
| S0 | lock: `enable_rc` (on exit: `restart`, because the device does not have `skips-restart`) | DISABLE_RC, ENABLE_RC "PRIUS" |
| S1 | `panamera_prepare_write`: stop ESM | WRITE_TO_MEMORY `0x2000FC` <- `21 00 00 00`; sleep 1 ms |
| S2 | disable quad SPI mode | READ_FROM_MEMORY `0x200FC0` (16 bytes); WRITE_TO_MEMORY `0x200FC0` <- `00 00 00 00` |
| S3 | disable HDCP 2.2 | READ_FROM_MEMORY `0x200F90` (4); WRITE_TO_MEMORY `0x200F90` <- value with bit 2 of byte 0 cleared |
| S4 | `update_esm`: CAL_EEPROM_CHECKSUM(`0x40000`, `0x40000`) vs byte-sum of file ESM; **skip if equal** | else: FLASH_ERASE 64K sectors 4,5,6,7 (`0x3004..0x3007`), sleep 5000 ms, WRITE_TO_EEPROM 0x40000.. in 64-byte blocks (32-byte RC chunks), re-checksum; whole thing retried up to 10x |
| S5 | `get_active_bank_panamera` | READ_FROM_MEMORY `0x20010C` (64 bytes); `bank = (u32[0] & BIT(7)) || (u32[0] & BIT(30)) ? 1 : 0`; `bank_to_update` = the other one |
| S6 | size | `fw_size = be32(file[0x400]) + 0x410`; must be <= `0x1A000`; `if (fw_size < file_size) fw_size = 0x1A000` (so always 0x1A000 for a 512 KiB file); checksum = CRC-16 of `file[0..fw_size)` |
| S7 | erase new bank | FLASH_ERASE data `u16 LE (0x3000 + 2*bank)` and `(0x3000 + 2*bank + 1)` (RC_LEN 2, offset 0); sleep 5000 ms |
| S8 | write | WRITE_TO_EEPROM of `file[0..0x1A000)` to `bank*0x20000 + i`, 32-byte RC chunks; a failed chunk is retried once |
| S9 | verify | CAL_EEPROM_CHECK_CRC16(`bank*0x20000`, `0x1A000`) four times with 1 ms sleeps, last result must equal the CRC-16; S7-S9 retried up to 10x (2 ms apart) |
| S10 | tag new bank valid | WRITE_TO_EEPROM 16 bytes at `bank*0x20000 + 0x1FFF0` (the tag above, today's date, CRC-16); sleep 1 ms; READ_FROM_EEPROM 16 bytes, must match; retried up to 10x |
| S11 | invalidate old bank | READ_FROM_EEPROM 1 byte at `old*0x20000 + 0x1FFFF`; if != 0xFF: FLASH_ERASE `u16 LE (0x1000 + (old*0x20000 + 0x1F000)/0x1000)` (= `0x101F` / `0x103F`); then WRITE_TO_EEPROM 1 byte `00` at `old*0x20000 + 0x1FFFF`; read back must be `00`; retried up to 10x |
| S12 | settle | sleep 2000 ms |
| S13 | restart (locker close) | WRITE_TO_MEMORY `0x2000FC` <- `F5 00 00 00`, error ignored ("triggers before returning") |

Note what S8 does **not** write: `0x1A000-0x1FFEF` stays erased (FF), unlike Dell's own halves (00).

### 2.3 synaptics-mst does not handle the WD19

`fu_synaptics_mst_device_setup` ends with

```c
} else {
    /* devices are explicit opt-in */
    g_set_error(error, ..., "ignoring %s device with no SynapticsMstDeviceKind quirk", guid0);
```

and `synaptics-mst.quirk` has no `[MST-259]` entry (board 0x0103). Also
`fu_plugin_add_rule(plugin, FU_PLUGIN_RULE_BETTER_THAN, "synaptics_mst")` in the dell-dock plugin.
**So fwupd has never updated a WD19 hub over DP AUX.** The DPCD procedure is proven on other Panamera
products (Dell systems, Lenovo docks), not on this dock.

## 3. fwupd dell-dock (EC USB-HID -> I2C transport)

Path: USB HID set/get report to the dock's hub device (`413C:B06E`), command `0x40/0xC6` (I2C write)
and `0x40/0xD6` (I2C read) to I2C target `0x72` at 400 kHz. The Panamera's RC mailbox is mapped in
its memory:

| Register | Address |
|---|---|
| RC trigger | `0x2000FC` (write u32 `0xF2` = execute; same register as stop-ESM/reboot) |
| RC command | `0x200110` (u32 LE `(cmd | 0x80) << 16`; completion: byte 2 bit 7 clear, result in byte 3) |
| RC offset | `0x200114` |
| RC length | `0x200118` |
| RC data | `0x200120` |
| boot status | `0x20010C` |

`fu_dell_dock_mst_rc_command` writes cmd/offset/length/(4 pad)/data in one I2C write starting at
`0x200110`, then writes `0xF2` to `0x2000FC` and polls `0x200110` up to 1000x2 ms. Result 4 means
"RC disabled" and triggers a re-enable. Same command codes as synaptics-mst (`fu-dell-dock.rs`:
Checksum 0x11, EraseFlash 0x14, WriteFlash 0x20, WriteMemory 0x21, ReadFlash 0x30, ReadMemory 0x31).

Order (`fu_dell_dock_mst_write_firmware` / `write_panamera`):

| # | Step | Exact traffic |
|---|---|---|
| D0 | open: `fu_dell_dock_set_power(device, unlock_target=9, TRUE)` | EC command `EC_CMD_MODIFY_LOCK 0x0a`, len 2, target 9 (MST), 1 = unlock |
| D1 | enable RC | ENABLE_RC "PRIUS" (disable+enable on failure) |
| D2 | `query_active_bank` | read 4 bytes at `0x20010C`, same bit 7 / bit 30 rule |
| D3 | `stop_esm` | WriteMemory `0x2000FC` <- `0x21`; sleep 1 ms; ReadMemory `0x200FC0` (4), write back with byte 0 = 0; ReadMemory `0x200F90` (4), write back with `data_out[0] = data[0] & (1 << 2)` (see 4.1) |
| D4 | order = {ESM, other bank} | |
| D5 | for each: `checksum_bank` = CMD 0x11 over (start, length) vs byte sum of the **file** at the same offsets; skip if equal | bank n: (`n*0x20000`, `0x20000`); ESM: (`0x40000`, `0x3ffff`) (see 4.1) |
| D6 | else `write_bank` (up to 2 attempts): erase 64K sectors with 4-byte data `u32 LE 0x3000 | (addr/0x10000)`, sleep 5000 ms; write the **whole 128 KiB half of the file** (`data + i` for `i` in the bank range, tag included) in 32-byte WriteFlash commands; re-checksum | |
| D7 | `invalidate_bank(bank_in_use)` | ReadFlash 4 bytes at `old + 0x1FFF0 + 12` ("4 byte increments over I2C"); if CRC byte != FF: erase 4K sector `0x1000 + (old + 0x20000 - 0x1000)/0x1000`; else WriteFlash 4 x `00` at `old + 0x1FFFC`; re-read, accept FF-after-erase or 00-after-write; up to 3 tries |
| D8 | disable RC; close: `set_power(9, FALSE)` (re-lock) | |
| D9 | composite cleanup: `fu_dell_dock_ec_reboot_dock` | EC `EC_CMD_PASSIVE 0x0d` with `passive_flow` (default `PASSIVE_REBOOT_MASK`): the EC reboots the whole dock when the host lets go |

The dell-dock quirk marks the MST `skips-restart,dual-image,usable-during-update`; the MST is never
restarted by the plugin itself.

This is the path that flashed this dock yesterday: D5/D6 wrote the bank-0 half of 01.00.20 into bank 0
(ESM skipped, identical), D7 erased bank 1's tag sector, D9 rebooted the dock. Because the package is
applied as a whole, the EC and USB hubs were flashed too. FirmwareKit only ever talks to the hub.

## 4. Ambiguities, discrepancies and bugs in the reference code

4.1 Quoted discrepancies between the two plugins on the **same chip**:

* HDCP 2.2 register. synaptics-mst: `buf[0] = buf[0] & (~BIT(2));` (clear bit 2).
  dell-dock: `data_out[0] = data[0] & (1 << 2);` (keep only bit 2, clear the rest). They agree only if
  byte 0 is 0. FirmwareKit follows synaptics-mst (our transport's reference) and puts the exact value,
  computed from a pre-read, into the plan. **Unverified which is right.**
* Quad register. synaptics-mst writes `buf[0] = 0x00` as a u32 (all four bytes 0); dell-dock zeroes byte
  0 and writes bytes 1..3 back. Agree if bytes 1..3 are 0. FirmwareKit writes 4 zero bytes.
* ESM checksum length: dell-dock `esm_attributes.length = 0x3ffff` (last byte excluded),
  synaptics-mst `ESM_CODE_SIZE 0x40000`. Irrelevant for us: we never write ESM, we only compare it.
* What is written into the new bank: synaptics-mst writes `0x1A000` bytes + a self-made tag (today's
  date, real CRC-16 in bytes 4..5), leaving `0x1A000-0x1FFEF` = FF; dell-dock writes Dell's complete
  half including Dell's tag (fixed date, `4a 51`). Both produce booting devices, which is our main
  evidence that the boot ROM ignores tag bytes 1..14 (assumption A4).
* Erase data: synaptics-mst sends 2 bytes (RC_LEN 2), dell-dock 4 bytes with the same low 16 bits.
* Invalidation: synaptics-mst erases the tag sector (if CRC != FF) and then programs `00` into the CRC
  byte; dell-dock does either the erase or the `00` write.
* dell-dock bug: `fu_dell_dock_mst_read_register(proxy, PANAMERA_MST_RC_DATA_ADDR, 1, &bytes, error)`
  followed by `crc_tag = g_bytes_get_data(bytes, NULL); ... crc_tag[3]`. `fu_dell_dock_hid_i2c_read`
  returns `g_bytes_new(cmd_buffer.data, read_size)` with `read_size = 1`, so `crc_tag[3]` is an
  out-of-bounds heap read. Which branch runs is therefore not determined by the source; the dump shows
  the erase branch ran on this dock.
* synaptics-mst `verify CRC` loop: reads CRC-16 four times and only the last value is compared
  (`for (i = 0; i < 4; i++) { sleep 1; get ... }`): suggests the first reads can be stale. We use
  CMD 0x11 (what dell-dock uses on this dock) plus a full read-back; 0x17 is optional and off.
* Active-bank bits: both plugins use `BIT(7) || BIT(30)` of `0x20010C`; dell-dock's `d19_check_fw`
  documents byte 0 bits 0-3 as firmware/HDCP/config0/config1 checks, `0xF0` as "running in bootloader",
  byte 1 error code, byte 2 GPIO strap, byte 3 bootloader version. Bit 7 thus overlaps the "bootloader"
  nibble; neither plugin explains it.

4.2 Not in any source: what the boot ROM does with **two** valid tags or **none**.

## 5. What FirmwareKit does

Content and ordering follow dell-dock (proven on this dock), command forms follow synaptics-mst (DPCD).
Differences from both are deliberate and marked "(new)".

| fwupd step | FirmwareKit step (`FlashPlan` stage) |
|---|---|
| (none) | **backup**: full 512 KiB read twice, must be identical, saved with JSON sidecar (date, DPCD version, active bank, sha256, tags, ESM sum) (new) |
| S5/D2 + setup | **snapshot** (read-only): DPCD identity, RAM `0x1700` signature, `0x170E` board id, `0x20010C`, both tags, CMD 0x11 over each bank and ESM, `0x200FC0`/`0x200F90` |
| fwupd board-id check (`prepare_firmware`) | **guards** (section 6) |
| S0/D1 | `preflight`: ENABLE_RC, then re-verify every snapshot value (device unchanged since planning) |
| S1-S3 / D3 | `prepare`: `0x2000FC` <- `21000000`, 1 ms, `0x200FC0` <- `00000000`, `0x200F90` <- pre-read with bit 2 cleared; then a flash read to prove reads still work |
| S4 / D5(ESM) | **ESM never written**: guard requires device ESM sum == target ESM sum, else refuse |
| S7 / D6 erase | `eraseInactive`: FLASH_ERASE `0x3000+2n`, `0x3001+2n` (2-byte form), sleep 5000 ms |
| (none) | `verifyErased`: CMD 0x11 over the bank == `0x01FE0000`, and full read-back == FF (new) |
| S8 / D6 write | `writeBody`: Dell's half for that bank, `0x00000-0x1FFEF` only, 4096 WRITE_TO_EEPROM of <= 32 bytes, retried once on transport error |
| S9 / D6 checksum | `verifyBody`: full read-back compare + CMD 0x11 over `0x1FFF0` (+ CMD 0x17 over `0x1A000` if `verifyWithCRC16`) |
| S10 / (D6, implicit) | `writeTag`: 16 bytes at `+0x1FFF0` = **Dell's tag for that bank** (not a self-made one). Written only after the body verified (new: dell-dock writes the tag as part of the stream, before any check) |
| S10 verify | `verifyTag`: read-back of the tag + CMD 0x11 over the whole bank |
| S11 / D7 | `invalidateOld`: re-read old tag; FLASH_ERASE `0x101F`/`0x103F` (old bank's last 4 KiB). Only reachable after `verifyTag` passed. No `00` write afterwards (dell-dock erase branch) |
| (none) | `verifyInvalidated`: old tag sector all FF, CMD 0x11 over the old bank's first `0x1F000` == backup, new tag still present (new) |
| S12-S13 / D9 | `restart`: default **DISABLE_RC and ask the user to unplug the dock's power for 10 s** (new); optional `.rcReboot` = sleep 2000 ms + `0x2000FC` <- `F5000000` |
| (none) | `confirmAfterRestart`: DPCD `0x50A` == target, `0x20010C` says the new bank |

Mutating operations for one run: 3 memory writes, 2 erases, 4096 body writes, 1 tag write, 1 erase
(+1 restart write) = 4103. All of them are visible in `FlashPlan.mutatingOps` before anything runs.

Safety properties enforced in code:

* `WriteAuthorization` has a `fileprivate` initialiser in `FlashExecutor.swift`; every mutating
  `HubTransport` call requires one. Only `FlashExecutor.execute(_:allowWrites: true)` creates it, after
  `plan.validate()` and a passing guard report. Default `allowWrites: false` = dry run: all reads are
  executed, every erase/write is logged as `WOULD SEND ...`.
* `FlashPlan.validate()` (planner and executor): writes only inside the inactive bank, body writes
  contiguous and byte-equal to the target, exactly one tag write with a valid tag for that bank, 64K
  erases only of the inactive bank's two sectors, the only erase touching the running bank is its tag
  sector and only in `invalidateOld` after `verifyTag`, memory writes only to the 3 prepare registers
  (`0x2000FC` only with `21000000`), no ESM access, no chip erase.
* Executor stops at the first failed verification and disables RC; it never reaches the invalidation
  unless the new bank verified. `stopAfter:` is accepted only for stages after which the running bank
  is still the only valid one (`preflight`, `prepare`, `verifyErased`, `verifyBody`).
* Restore: `FlashTarget.restore(from: backup, knownImages:)` maps the backup's running firmware to the
  byte-identical Dell image (Dell's tags). If none matches it refuses unless `allowSynthesizedTag`
  (re-targeted tag: bank byte + CRC-8 changed; for Dell firmware this equals Dell's tag, tested).
  `FlashTarget.dell(latest)` targets 05.07.08 (01.00.31, the newest package in the table).

Package handling: `FirmwarePackage` hashes the `.cab` and refuses unknown hashes before extracting;
extraction shells out to `/usr/bin/tar -x -f <cab> -C <tmp> vmm5331.bin` (macOS libarchive reads
MSZIP cabinets; checked on all 10 packages), then the image hash is checked again and the image is
parsed strictly (`VMMImage.parse`: known hash, both halves structurally WD19, tags valid, halves equal
except tag, version at `0x18400` and ESM sum equal to the table). Built-in table: 10 packages; flash
targets only 05.07.01/04/07/08 (same ESM as this dock). Download URL for 01.00.20 (given, verified):
`https://fwupd.org/downloads/0572352b20a0b071331971f0698625afdd140596f2e38a24359aaf25c8ab4cf8-DellDockFirmwareUpdateLinux_01.00.20.cab`;
the others follow the same `<sha256>-<filename>` LVFS pattern (marked `urlVerified: false`). No network
code exists in the module.

## 6. Guards (all must pass; `Guards.evaluate`)

| Check | Why |
|---|---|
| DPCD `0x500` OUI `90 CC 24` | Synaptics branch device |
| DPCD `0x503` device id starts `SYNA` | Synaptics puts "SYNA" + chip id there ("SYNAS1") |
| DPCD `0x507` chip id `0x5331` | VMM5331 / Panamera layout |
| DPCD `0x4B0` bit 2 | RC available |
| RAM `0x1700` = `20 00 83 83` | config block layout we parsed |
| RAM `0x170E` = `01 03` | customer Dell, board WD19 (dell-dock `MST-panamera-vmm5331-259`); same check fwupd does in `prepare_firmware` (board id from image `0x10E` == device) |
| image board id == device board id | as fwupd |
| running bank's tag valid (CRC-8, bank byte) | we only understand boot selection in this state |
| ESM sum on chip == target ESM sum | ESM is never rewritten |
| verified backup present, taken from **this** state | running bank tag, CMD 0x11 sum of the running bank and ESM sum equal the backup |
| DPCD version == version bytes of the running bank in the backup | active-bank register and flash agree |
| running bank code ends <= `0x1F000` and its tag sector holds only 00/FF | erasing that sector cannot remove code |
| Mac on AC (`IOPSGetProvidingPowerSourceType`, injectable) | the host process must not die mid-write; unknown counts as failure |

Not checkable from the host: the dock's own power. The user must be told not to unplug the dock.

## 7. Assumptions not verified from source or dumps

| # | Assumption | Status / evidence |
|---|---|---|
| A1 | The WD19 hub accepts RC 0x14/0x20/0x11 over **DPCD** like other Panamera devices do | not tested anywhere; dell-dock uses the same codes over I2C on this chip; our DPCD RAM write (0x21) works |
| A2 | `0x20010C` bit 7 / bit 30 = running bank 1 | both plugins agree; never read on this Mac |
| A3 | Boot ROM boots the bank whose tag has valid CRC-8 and matching bank byte; FF tag = invalid | consistent with the dump; behaviour with two valid tags / none is unknown, so our order never creates "none" and the simulator requires both candidates to be intact |
| A4 | Tag bytes 1..14 are not checked against content | Dell's constant `4a 51` vs fwupd's real CRC-16 both boot. FirmwareKit writes Dell's bytes |
| A5 | Bytes `0x1F000-0x1FFEF` are not covered by any boot-time check | code ends at `0x18406`; Dell pads with 00, synaptics-mst leaves FF |
| A6 | Erase code `0x3000+n` = 64 KiB sector n, `0x1000+n` = 4 KiB sector n | both plugins; matches the dump's erased 4 KiB |
| A7 | 32-byte writes at 32-aligned addresses and a 16-byte write at `+0x1FFF0` are accepted | synaptics-mst does both |
| A8 | CMD 0x11 = plain byte sum, u32 LE, works for any (offset, length) | dell-dock compares it to a byte sum over 0x20000 / 0x3ffff |
| A9 | The prepare pokes are needed and harmless; the HDCP/quad discrepancy (4.1) does not matter | unverified |
| A10 | Commands complete within the poll window (fwupd: 3 s; proposed C: 10 s) and a 64 KiB erase finishes before the command reports done | fwupd also sleeps 5 s after erases; we do too |
| A11 | The hub keeps running while its inactive bank and its own tag sector are erased/programmed | both plugins do it; dell-dock did it on this dock |
| A12 | The dock EC does not drive the same RC mailbox over I2C while we use it over DPCD | unknown; dell-dock "unlocks" the MST through the EC first (D0) |
| A13 | A dock power cycle re-runs bank selection | expected (ROM decision at boot) |
| A14 | After boot, DPCD `0x50A` = bytes at `0x18400` of the running bank | true in the dump (05.07.08 / bank 1) |

## 8. Recommended transport

**DPCD RC through CDock**, for these reasons: no USB HID access to the dock (dell-dock needs the
dock's HID interface and the EC protocol, i.e. touching the component that was unintentionally
downgraded yesterday), it reuses code that already works on this Mac (RC enable, memory/flash reads,
a RAM write), it addresses only the MST hub, and the RC command set is the same chip-level protocol
dell-dock uses.

Honest downsides:

* It bypasses dell-dock's interlocks: the EC is never told (no `MODIFY_LOCK` unlock of target 9, no
  re-lock, no passive-flow reboot). We do not know what the EC does with the MST during an update; if
  it talks to the RC mailbox over I2C concurrently, commands could interleave (A12). Mitigation: full
  read-back plus chip checksum after every stage, and the old bank is invalidated only after that.
* fwupd never used DPCD on a WD19 (section 2.3). We found no code or quirk saying Dell docks reject or
  mishandle DPCD-side updates, and no evidence that they accept them. That is the first thing the
  hardware experiments must establish.
* The restart path is different: dell-dock relies on the EC rebooting the whole dock. We ask the user
  to power-cycle the dock (the `F5` RC reboot is optional and untested on WD19).

If experiment E3/E5 shows anything inconsistent, the fallback is to implement the dell-dock I2C path
for the MST only (D0-D8 without any EC/USB-hub firmware), behind the same `HubTransport` protocol.

## 9. Proposed CDock additions (C patch, not applied)

Read-only checksums go next to the existing read API. Everything that modifies the hub lives on a
separate allow-list (`td_fw_*`) that is refused unless the session was armed, and refuses anything that
would touch the running bank except its tag sector.

```c
/* ---- cdock.h ---- */
// Read-only RC computations (the hub sums its own flash; nothing is modified).
int td_rc_checksum(td_dock *d, uint32_t addr, uint32_t len, uint32_t *sum);  // RC 0x11, byte sum
int td_rc_crc16(td_dock *d, uint32_t addr, uint32_t len, uint32_t *crc);     // RC 0x17

// Firmware update primitives. Separate allow-list. All return -102 unless td_fw_arm() was called
// in the current RC session; td_rc_disable()/td_close() disarm.
#define TD_FW_ARM_MAGIC 0x5331F1A5u
int td_fw_arm(td_dock *d, uint32_t magic);
// 4 bytes to 0x2000FC (only 21 00 00 00 or F5 00 00 00), 0x200FC0 or 0x200F90.
int td_fw_write_memory(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len);
// Only 0x3000..0x3003 (64K sectors of bank 0/1) and 0x101F/0x103F (bank tag sectors);
// refuses 64K sectors of the running bank and the tag sector of the inactive bank.
int td_fw_erase(td_dock *d, uint16_t code);
// addr + len <= 0x40000, 1..32 bytes, no 32-byte boundary crossing, never inside the running bank.
int td_fw_write_flash(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len);
```

```c
/* ---- cdock.c ---- */
struct td_dock { IODPDeviceRef dev; bool rc_on; bool fw_armed; };   // + fw_armed

enum { CMD_CAL_CHECKSUM = 0x11, CMD_FLASH_ERASE = 0x14, CMD_CAL_CRC16 = 0x17, CMD_WRITE_FLASH = 0x20 };
enum { REG_BOOT_STATUS = 0x20010C, REG_MCU_CMD = 0x2000FC, REG_QUAD = 0x200FC0, REG_HDCP22 = 0x200F90 };

// Second, separate allow-list. rc_exec() above is unchanged and still cannot send 0x11/0x14/0x17/0x20.
static int rc_exec_fw(td_dock *d, uint8_t cmd, int timeout_ms) {
    bool ro = cmd == CMD_CAL_CHECKSUM || cmd == CMD_CAL_CRC16;
    bool rw = cmd == CMD_FLASH_ERASE || cmd == CMD_WRITE_FLASH || cmd == CMD_WRITE_MEMORY;
    if (!ro && !rw) return -100;
    if (!d->rc_on) return -101;
    if (rw && !d->fw_armed) return -102;
    uint8_t c = cmd | 0x80;
    if (td_dpcd_write(d, RC_CMD, &c, 1)) return -1;
    for (int waited = 0; waited <= timeout_ms; waited += 10) {
        uint8_t s[2];
        if (td_dpcd_read(d, RC_CMD, s, 2)) return -1;
        if (!(s[0] & 0x80)) return s[1];
        usleep(10000);
    }
    return -2;
}

static int rc_args(td_dock *d, uint32_t addr, uint32_t len) {
    uint8_t b[4];
    le32(b, addr); if (td_dpcd_write(d, RC_OFFSET, b, 4)) return -1;
    le32(b, len);  if (td_dpcd_write(d, RC_LEN, b, 4)) return -1;
    return 0;
}

static int rc_calc(td_dock *d, uint8_t cmd, uint32_t addr, uint32_t len, uint32_t *out) {
    if (!len || addr > 0x80000 || len > 0x80000 - addr) return -100;
    if (rc_args(d, addr, len)) return -1;
    int r = rc_exec_fw(d, cmd, 10000);
    if (r) return r > 0 ? -r - 10 : r;
    uint8_t b[4];
    if (td_dpcd_read(d, RC_DATA, b, 4)) return -1;
    *out = b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
    return 0;
}
int td_rc_checksum(td_dock *d, uint32_t a, uint32_t l, uint32_t *s) { return rc_calc(d, CMD_CAL_CHECKSUM, a, l, s); }
int td_rc_crc16(td_dock *d, uint32_t a, uint32_t l, uint32_t *c)    { return rc_calc(d, CMD_CAL_CRC16, a, l, c); }

int td_fw_arm(td_dock *d, uint32_t magic) {
    if (!d->rc_on || magic != TD_FW_ARM_MAGIC) return -102;
    d->fw_armed = true;
    return 0;
}
// td_rc_disable(): add `d->fw_armed = false;`

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
    if (td_dpcd_write(d, RC_DATA, buf, 4) || rc_args(d, addr, 4)) return -1;
    int r = rc_exec_fw(d, CMD_WRITE_MEMORY, 3000);
    return r > 0 ? -r - 10 : r;
}

int td_fw_erase(td_dock *d, uint16_t code) {
    int rb = running_bank(d);
    if (rb < 0) return -1;
    bool ok64 = code >= 0x3000 && code <= 0x3003 && (code & 0xF) / 2 != rb;   // inactive bank only
    bool okTag = code == (rb ? 0x103F : 0x101F);                               // running bank's tag sector
    if (!ok64 && !okTag) return -100;
    uint8_t b[2] = { (uint8_t)code, (uint8_t)(code >> 8) };
    if (td_dpcd_write(d, RC_DATA, b, 2) || rc_args(d, 0, 2)) return -1;
    int r = rc_exec_fw(d, CMD_FLASH_ERASE, 10000);
    return r > 0 ? -r - 10 : r;
}

int td_fw_write_flash(td_dock *d, uint32_t addr, const uint8_t *buf, uint32_t len) {
    if (!len || len > 32 || addr / 32 != (addr + len - 1) / 32 || addr + len > 0x40000) return -100;
    int rb = running_bank(d);
    if (rb < 0 || addr / 0x20000 == (uint32_t)rb) return -100;
    if (td_dpcd_write(d, RC_DATA, buf, len) || rc_args(d, addr, len)) return -1;
    int r = rc_exec_fw(d, CMD_WRITE_FLASH, 3000);
    return r > 0 ? -r - 10 : r;
}
```

`running_bank()` per write costs one extra RC read (~7 ms) per 32-byte write (~30 s per bank); worth it
for defence in depth, or cache it per armed session. `CDockTransport` then maps `rcFlashSum32` ->
`td_rc_checksum`, `rcFlashCRC16` -> `td_rc_crc16`, `rcWriteMemory` -> `td_fw_write_memory`,
`rcEraseFlash` -> `td_fw_erase`, `rcWriteFlash` -> `td_fw_write_flash`, and arms the session right
after `rcEnable` inside the executor's run only.

## 10. Risk analysis: state if the process (or the Mac) dies at each step

The dock keeps its own power in all these cases; "power loss" of the dock itself is the same as the
case below plus a reboot. Simulator coverage: `everyBoundaryIsBootable` checks after every one of the
4103 mutating commands; `interruptAndRecover` interrupts (clean and half-applied) at every non-body
command and sampled body writes, power-cycles with both possible ROM preferences, and re-runs to
completion.

| Interrupted during / after | Flash state | Boots | Recovery |
|---|---|---|---|
| backup, snapshot, preflight | unchanged | old | none needed |
| prepare | unchanged; RAM: ESM stopped, quad off, HDCP 2.2 off | old (until reboot: degraded HDCP) | power-cycle the dock |
| eraseInactive / verifyErased | inactive bank partly/fully FF, tag FF | old (only valid tag) | power-cycle, new backup, re-run |
| writeBody / verifyBody | inactive bank partly programmed, tag FF | old | same |
| writeTag (torn) | new tag partly programmed, CRC-8 almost surely invalid | old | same (if by chance valid: body is already verified, both intact) |
| after writeTag, before invalidation | two valid tags, both banks verified intact | either (A3 unknown) | re-run: the planner treats whichever booted as running, writes the target into the other bank |
| invalidateOld (torn 4 KiB erase) | old tag erased, or partly erased (CRC invalid), or still intact | new, or either | re-run / nothing |
| after verifyInvalidated | only new tag valid | new | power-cycle |
| restart (`F5`) | unchanged | new | power-cycle if the hub does not come back |

Unreachable by this ordering, but the worst case if a bug or a wrong assumption (A1, A6) erased the
running bank: no valid tag, boot behaviour unknown (ROM may stay in its bootloader; dell-dock's status
decoding has a "running in bootloader" state). Recovery would then be fwupd **dell-dock** from Linux
(I2C through the EC does not need working MST firmware, but that is also unverified), writing the
saved backup's bank half. Keep the Linux VM until the native path has been proven.

ESM is never written, so the only non-redundant region of the flash is never at risk.

## 11. Hardware experiments before the first real write (in order)

E1-E4 are read-only. Each needs a small CLI wrapper around FirmwareKit + `CDockTransport`.

* **E1 identity and bank state (A2, A3, A14).** `DeviceReader.identity`, RC read `0x20010C` (4 and 64
  bytes), flash `0x1FFF0` and `0x3FFF0` (16 bytes each), RAM `0x170E` (2), `0x200FC0` (16), `0x200F90`
  (4). Expected after yesterday: 05.07.04, status bits 7 and 30 clear (bank 0), tag 0 =
  `000c0d174a5100000000000000000064`, tag 1 all FF. Note the two register values for 4.1.
* **E2 backup (stability, layout).** `Backup.create` (two full reads, ~4 min). Expected:
  bank 0 == 01.00.20 bank-0 half exactly, bank 1 `0x00000-0x1EFFF` == the old dump's bank 1,
  `0x3F000-0x3FFFF` FF, ESM == dump. Run `FlashAnalysis` on it.
* **E3 checksum command (A8, A10).** Add `td_rc_checksum` (read-only) and compare CMD 0x11 over
  (`0x0`, 32), (`0x0`, `0x20000`), (`0x20000`, `0x20000`), (`0x40000`, `0x40000`) with the backup;
  log completion time. Then `DeviceReader.snapshot` + `FlashPlanner.plan` + `FlashExecutor.execute`
  in **dry-run** against the real dock: all preflight comparisons must pass.
* **E4 (optional) CRC-16 command.** `td_rc_crc16` over (`0x0`, `0x1A000`) vs `Checksum.crc16`.
* **E5 first write, still no tag (A1, A6, A7, A10, A11, A12).** Plan "05.07.04 into the inactive bank
  1" (re-flashing the version already running, so nothing is lost either way) and
  `execute(plan, allowWrites: true, stopAfter: .verifyBody)`: erases bank 1 (currently invalidated
  05.07.08 code), programs the body, verifies by read-back and CMD 0x11, never writes the tag, never
  touches bank 0. Then power-cycle the dock and repeat E1: must still be 05.07.04 from bank 0. This is
  the first step with real risk: if the erase code were misinterpreted it could hit bank 0.
* **E6 full run.** Same plan without `stopAfter`, power-cycle, `confirmAfterRestart`: expect 05.07.04
  from bank 1 and bank 0's tag sector erased. Then (optional) the restore direction (05.07.08 into bank
  0 and back) to exercise both bank numbers.

This dock already runs 05.07.04, so E5/E6 are only needed to prove the path for other users.

## 12. Building and testing

```
swift build --scratch-path .build-fw --target FirmwareKit
swift test --scratch-path .build-fw --filter FirmwareKitTests \
    -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

The Command Line Tools have no XCTest, so the tests use Swift Testing. With CLT 6.4.2 the
`emit-module` job does not get the Testing macro plugin path ("plugin for module 'TestingMacros' not
found"), hence the extra `-Xswiftc` flags. Tests that need the dump or the cabinets are disabled when
the files are missing; override their locations with `TWINDESK_FWDUMP_DIR` and `TWINDESK_CAB_DIR`.
