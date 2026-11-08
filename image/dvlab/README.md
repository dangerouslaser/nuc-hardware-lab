# dvlab: Dolby Vision through the NUC7's MCDP2800

The `dvlab` variant of the USB image runs the experiments in
`docs/MCDP2800-DV-PLAN.md`. It is the survey image plus:

- the LibreELEC-yblod 0.3.3 kernel (Linux 7.3 at `a90ee4305c`, the yblod
  patch series) with **one lab-only patch**,
  `linux-9990-nuclab-lspcon-dv-lab.patch`, built with Alpine's `linux-lts`
  config so the module allowlist and the no-internal-disk rule still hold;
- `dvprobe` (one modeset + one experiment per run, then exit);
- two 3840x2160 Dolby Vision tunnel frames (a valid one, and the same frame
  with every metadata CRC broken);
- `i915.lspcon_dv_lab=1` on the kernel command line, and a `[D]` menu entry.

Never ship any of this in a LibreELEC-yblod release.

## What the lab patch does

It adds `i915_lspcon_dv_lab` and `i915_lspcon_dv_lab_dpcd` to the DP
connector's debugfs directory, only when `i915.lspcon_dv_lab=1`, only on a
VBT-declared LSPCON port, and only with a MegaChips converter on gen9/10. It
writes nothing until a command is written to the file:

| Command | AVI (MCA mailbox 0x5C0) | Dolby VSIF |
|---|---|---|
| `off` | the driver's own (re-run of the enable path) | none |
| `avi` | DV-style: RGB, full range, CTA VIC, no colorimetry | none |
| `h1` | DV-style | VS DIP, DP InfoFrame SDP form |
| `h1b` | DV-style | VS DIP, DP InfoFrame SDP form with HB2 = 0x1c |
| `h2` | DV-style | GMP DIP, DP InfoFrame SDP form |
| `crc` | - | - (reads DP_TEST_CRC if the branch supports it) |

Any modeset or fastset ends an experiment. Every command waits for an
in-flight commit to finish programming the hardware first. Experiments are
refused (EINVAL) unless the pipe sends RGB at full range. Reading the file dumps the DIP control
register, the VS and GMP DIP contents, and the last sink CRC.

### Wire encodings (plan section 6.2)

On gen9 every HSW-style DIP data buffer is 32 bytes. DW0 is
`HB0 HB1 HB2 <byte 3>`: byte 3 is the HDMI ECC hole, or HB3 in DP mode.

- **HDR10 on LSPCON today (the C2 control):** `intel_ddi_enable_dp()` calls
  `intel_dp_set_infoframes()`, which writes the GMP DIP via
  `intel_dp_hdr_metadata_infoframe_sdp_pack()` as a DP 1.4 InfoFrame SDP:
  `00 87 1d 4c | ver len | 26 payload bytes`, without the checksum. The
  converter turns that into the HDMI DRM InfoFrame (type 0x87).
- **h1 / h2:** the Dolby VSIF in the same form:
  `00 81 1d 4c | 01 1b | 46 d0 00 02 00 ...` (PB1..PB26). PB27 does not fit
  in 32 bytes. It is reserved (zero) in the Dolby VSIF, and the patch checks
  that.
- **h1b:** as h1, but HB2 = 0x1c, the exact data byte count minus one
  (version, length, 27 payload bytes), instead of the HDR path's fixed 0x1d.
  The HDMI-mode DIP layout (`81 01 1b 00 | cs ...`, used on native HDMI) is
  not tested: on an LSPCON port the transcoder is in DP mode, DW0 always goes
  out as the SDP header, and `81 01 1b 00` would be an Audio_TimeStamp SDP.

The VSIF is `hdmi_dolby_vendor_infoframe_init()` with `signal = 1`, the same
packet the native-HDMI DV path sends.

## The LG C3's EDID (plan section 6.1)

The EDID was already in the first report (`raw/modetest`, connector DP-1, 256
bytes). Its Dolby VSVDB is `eb 01 46 d0 00 48 22 7e 86 60 5e 96`: version 2,
interface 2 (Standard DV). The port's own parser (`dvbridge_parse_edid()`
from `linux-9902`) returns `standard-dv version=2 legacy_vsif=0 2160p60=1`, so
the C3 is a sink the port already supports, and VIC 93/97 stay in AVI. No
extra volunteer run was needed for this.

## Rebuilding

Kernel, on a Linux box with Docker (Ollie):

```sh
# linux/ = the patched 7.3 tree from a LibreELEC-yblod build
#          (build.*/build/linux-7.3, cleaned with make mrproper)
# alpine-lts.config = /boot/config-*-lts from alpine:3.24 linux-lts
cd linux && git apply ../linux-9990-nuclab-lspcon-dv-lab.patch
docker run --rm -v $PWD/..:/w alpine:3.24 /w/build-kernel.sh full
# -> nuclab-dvlab-kernel.tar.gz
```

Frames: `make-frames.sh WORKDIR` (needs dovi_tool, ffmpeg with libx265,
mkvmerge, Docker with the `yblod-sync-root` engine image, and an Intel GPU).
The frames are content-free: FFmpeg's testsrc2 picture plus a dovi_tool RPU
from `refclip-gen.json`. `tunnelcheck.py check` must report valid packets for
`dv-ref` and none for `dv-bad`. `frames.sha256` holds the expected hashes.

Image:

```sh
mkdir -p out/dvlab
cp nuclab-dvlab-kernel.tar.gz dv-ref.xrgb.zst dv-bad.xrgb.zst out/dvlab/
NUCLAB_VARIANT=dvlab sh image/build.sh        # -> out/nuclab-dvlab.img.gz
NUCLAB_VARIANT=dvlab sh image/test/qemu-smoke.sh
```

## Volunteer run

`[D]` (at the start, or from the final menu) runs `dvlab.sh`:
C1 → C2 → H1 → H1b → H2 → negative control → C1 again, then 59.94 Hz for the
first hypothesis the TV accepted. Each step: about 25 s of picture, then
questions on screen. The results go in `dvlab/` inside the encrypted report:
`answers.txt`, `dvprobe.log` (state dumps, DIP bytes, CRCs),
`lab-*.txt` and `dpcd-vendor.txt`.
