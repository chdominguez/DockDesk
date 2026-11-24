# mst-probe

A small macOS command-line tool that talks to a DisplayPort MST hub over the AUX channel, enumerates the monitors behind it, and tests what happens when the hub is forced into multi-stream mode.

It exists to answer one question: **can a third-party driver make macOS extend to two monitors behind an MST dock?** Short answer: not with MST, since the Mac never sends multi-stream framing. But on this dock the hub itself can split one wide stream across two monitors, on hub firmware 05.07.04 or older, and this tool switches that on.

## Test setup

| | |
|---|---|
| Mac | MacBook Air M5 (Mac17,3), macOS 27.2.1, SIP enabled |
| Dock | Dell WD19S (USB-C, DisplayPort alt mode, 2 lanes HBR3, not Thunderbolt) |
| MST hub in dock | Synaptics, OUI `90-cc-24`, device id `SYNAS1`, firmware 5.7 |
| Monitors | 2x Dell P2425H on the dock's two DisplayPort sockets |
| Symptom | Windows extends to both monitors; macOS shows the same image on both |

## Usage

```
make
./mst-probe dump                      # read-only DPCD dump
./mst-probe topology [-v]             # enumerate hub ports and monitors via sideband
./mst-probe force --revert-after 8    # switch the hub to MST, allocate payloads, revert
```

`-v` prints raw sideband messages. `force` blanks the external monitors until it reverts.

## How it works

DisplayPort has a low-speed side channel (AUX) next to the video lanes. Through it the source reads and writes the sink's register space (DPCD). MST is negotiated entirely through DPCD:

1. `MSTM_CAP` (0x021) says whether the device is an MST branch.
2. `MSTM_CTRL` (0x111) switches it between single-stream and multi-stream mode.
3. Sideband messages are written to `DOWN_REQ` (0x1000) and replies read from `DOWN_REP` (0x1400). They carry requests such as `LINK_ADDRESS` (list ports), `ENUM_PATH_RESOURCES` (bandwidth), `REMOTE_I2C_READ` (read a monitor's EDID through the hub) and `ALLOCATE_PAYLOAD`.
4. The source reserves time slots per stream in the payload table (0x1C0-0x1C2), then **its transmitter hardware** starts sending multi-stream transport packets and an ACT sequence on the main link.

Steps 1-3 and the register half of step 4 only need AUX access. macOS exposes that through a private IOKit API (`IODPDeviceReadDPCD` / `IODPDeviceWriteDPCD`, user client of `DCPDPDeviceProxy`). On macOS 27.2 it accepts an unentitled, unsigned process. Prototypes were recovered by disassembling `IOKit.framework`; see `src/iodp_private.h`.

The second half of step 4 happens inside the DP transmitter, which on Apple Silicon is driven by the DCP display coprocessor running Apple-signed firmware.

## Results

### 1. DPCD is readable and writable from userland

```
0x000 receiver caps: 12 14 c2 81 01 11 01 83 2a 3f 04 00 00 00 85 00
0x021 MSTM_CAP = 0x01  (MST capable: YES, single-stream sideband: no)
0x100 current link: rate 8.1 Gbps (HBR3), lanes 2
0x111 MSTM_CTRL = 0x00  (MST_EN=0 UP_REQ_EN=0 UPSTREAM_IS_SRC=0)
0x500 branch OUI 90-cc-24, device id "SYNAS1", hw 1.0, fw 5.7
```

macOS leaves the hub in single-stream mode (`MSTM_CTRL = 0`), so the hub clones the one stream to every output.

### 2. Both monitors can be enumerated individually

With sideband enabled (`MSTM_CTRL = 0x06`, video unaffected):

```
LINK_ADDRESS: branch reports 4 ports
  port 0: INPUT  peer=source/SST plugged=1
  port 1: OUTPUT peer=SST sink plugged=1 dpcd_rev=1.2
  port 2: OUTPUT peer=SST sink plugged=1 dpcd_rev=1.2
  port 3: OUTPUT peer=none plugged=0 dpcd_rev=0.0
  port 1:  full PBN 1280, available PBN 1280   EDID: DEL 0xa262 "DELL P2425H" serial <serial>
  port 2:  full PBN 1280, available PBN 1280   EDID: DEL 0xa262 "DELL P2425H" serial <serial>
```

At the same moment macOS reports `SinkCount = 1` and one display. The hub answers sideband requests even though `MSTM_CAP` does not advertise single-stream sideband support.

### 3. Forcing MST: the hub obeys, the Mac does not follow

`force` sets `MST_EN`, writes two payload table entries (27 slots each) and sends `ALLOCATE_PAYLOAD` for both ports.

- The hub accepted everything: `MSTM_CTRL` read back `0x07`, payload table status showed "updated", both `ALLOCATE_PAYLOAD` requests were acknowledged.
- Both external monitors went black for the whole window. The Mac kept transmitting single-stream framing, which an MST-mode hub cannot route.
- Lane status stayed locked (`0x77`), so the physical link was fine; only the framing was wrong.
- The hub reported `ACT handled = 1` although the Mac cannot have sent an ACT sequence. Treat that bit as unreliable on this hub.
- After restoring `MSTM_CTRL = 0`, macOS re-detected the display by itself within a few seconds. `IODPServiceRetrainLink` returned `0xe00002e2` (not permitted), so link retraining is entitlement-gated even though DPCD access is not.

### 4. No source-side switch found

- No MST-related property exists anywhere in the IO registry.
- The private IOKit DisplayPort API exports no MST, payload or stream-allocation calls. The only link controls are rate, lane count and drive settings.
- Not examined: the DCP firmware and the kernel extensions themselves. Both ship inside signed, compressed boot images, and modifying them would require lowering system security.

## Second attempt: the hub-side split trick (ViewXpand)

Since the Mac cannot send two streams, the remaining idea is to make the **hub** cut one wide stream in two. The dock's hub is a Synaptics VMM5331 ("Panamera"), and that family has a mode called ViewXpand: the hub advertises one combined display (3840x1080 for two 1080p monitors) and sends the left half to one output and the right half to the other. The [wd19-split](https://github.com/kksimp/wd19-split) project documented it for a Dell WD19 on hub firmware 05.06.03.

What was tested here (`hub-info`, `split on|off`, `mem`, `dump-flash`, `dump-ram`):

- **The Synaptics vendor protocol works from macOS over AUX.** The "remote control" registers at DPCD `0x4B0-0x4DF` (protocol as in fwupd's `synaptics-mst` plugin) accept `ENABLE_RC`, `READ_MEMORY`, `READ_FLASH` and `WRITE_MEMORY` from an unentitled process.
- **The layout matches the published notes.** Config block at RAM `0x1700` starts `20 00 83 83`, mode byte `0x1740` = `0x03` (pass-through), two monitors counted at `0x1821`.
- **Writing `0x1740 = 0x02` is accepted but has no effect on this dock.** After a monitor power cycle and a cable replug the upstream EDID (RAM `0x1600`) stayed a byte-for-byte copy of one monitor's EDID. No 3840x1080 timing appeared.
- **Re-plugging the dock to the Mac reboots the hub chip**, which reloads `0x1740 = 0x03` from flash.

### Why: the feature was removed from the firmware

Both flash banks were dumped read-only and disassembled (Ghidra, MCS-251 source mode, with a fix to Ghidra's 80251 decoder).

| | Bank 0 | Bank 1 (running) |
|---|---|---|
| Hub firmware | 05.07.04 | 05.07.08 |
| EDID builder | `FD61F7`, reads mode from `0x1740`, has the aggregate path | `FD1D92`, never reads `0x1740`, pass-through only |
| Picture split code | present (`FDE05F`) | absent |

In 05.07.08 no instruction references `0x1740`, and the code that programs the left/right split is gone. Replugging a monitor does run the EDID builder, but it can only pass one monitor's EDID through. Injecting a rebuild event would not help for the same reason. About 19 KB of the running bank was not reached by the disassembler and the chip also calls into on-chip ROM that is not in the dump, so this is strong but not absolute.

The older image in bank 0 (05.07.04) still contains the documented logic, with one extra condition: all connected monitors must report identical timings.

### What would be needed

Running hub firmware 05.07.04 or older. That means either switching the active flash bank or downgrading the dock firmware, both of which are **persistent flash operations with a real risk of bricking the dock's video**. This tool deliberately contains no flash write, erase or activate command.

## Result: it works on hub firmware 05.07.04

Dell's own older release `DellDockFirmwareUpdateLinux_01.00.20.cab` (LVFS, January 2024, sha256 `0572352b...4cf8`) contains hub firmware 05.07.04, byte-identical to the dock's inactive bank. It was installed with fwupd 2.0.20 from a Linux VM using USB passthrough of the dock's two management devices (`413c:b06e`, `413c:b06f`) and `--allow-older`.

Caveats from that install:

- fwupd 2.1.5/2.1.6 cannot see Dell docks at all (the EC dock-type query is skipped); 2.0.20 works.
- Passing the hub's device ID to `fwupdtool install` did **not** limit the update: all five components in the package were written (EC 01.01.00.16 -> 01.01.00.07, USB hubs 01.25 -> 01.22 and 01.66 -> 01.57, package -> 01.00.36.01, hub -> 05.07.04). The dock applies them when its USB-C cable is unplugged.

After the downgrade:

1. `mst-probe split on` sets RAM `0x1740 = 0x02`.
2. Replugging one monitor at the dock makes the hub rebuild its EDID, which now carries a 3840x1080 @ 60 Hz timing.
3. macOS offers that mode only as HiDPI through the public API; `displayplacer` can select the native 1x mode.
4. With 3840x1080 driven, the hub sets its split flag (RAM `0x182C = 1`, per-port width `0x1824 = 1920`) and each monitor shows one half of the desktop.

`./dual.sh on` does steps 1-3. The mode byte is volatile: it must be set again, followed by a monitor replug, every time the dock is reconnected to the Mac.

Limits: macOS sees one 3840x1080 display, not two (windows maximise across both, the menu bar spans both), and the refresh rate is 60 Hz instead of the monitors' 100 Hz.

## Conclusion

The missing piece is not a driver that talks to the dock. It is multi-stream packet framing in the DisplayPort transmitter, which lives in Apple's display coprocessor firmware and its kernel drivers. DriverKit has no display-output family, and a kernel extension could not replace the firmware. Whether the transmitter hardware could do MST at all is unknown from this experiment.

Ways to get two extended displays on this Mac:

- Plug the second monitor into the Mac's other USB-C port with a USB-C to DisplayPort cable. The M5 MacBook Air drives two external displays natively.
- Use a Thunderbolt dock (for example Dell WD19TB or WD22TB4), which tunnels two separate single-stream DisplayPort links.
- Use a DisplayLink dock, which sends compressed video over USB.

## Safety notes

- The Synaptics commands (`hub-info`, `split`, `mem`, `dump-*`) use vendor registers `0x4B0-0x4DF`. They are limited to an allowlist: enable/disable RC, read RAM, read flash, and one RAM byte write (`0x1740`). All of it is volatile.
- The standard commands write only volatile DPCD registers: `0x111`, `0x1C0-0x1C2`, `0x2C0`, `0x1000+`, and the IRQ acknowledge bits at `0x201` / `0x2003`. Unplugging the dock resets all of them.
- It uses private API that can change or disappear in any macOS update.
- Tested on exactly one Mac, one dock and one macOS version.

## Files

- `src/iodp_private.h` - recovered private IOKit prototypes
- `src/dpcd.c` - AUX read/write and register decoding
- `src/sideband.c` - MST sideband message encoding, CRCs, reply reassembly
- `src/main.c` - `dump`, `topology`, `force`
- `notes/` - raw captures from the runs described above

Sideband message layout and CRC routines follow the DisplayPort 1.2 standard and the behaviour of the Linux kernel's `drm_dp_mst_topology.c`.
