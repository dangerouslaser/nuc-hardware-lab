# Dolby Vision through the MCDP2800 LSPCON: agent plan

Audience: the agent working on the LibreELEC-yblod port
(`/Users/bryanhoban/Projects/libreelec-yblod-engine-integration`).
Written 2026-11-08 after the first successful volunteer survey. Read
`PLAN.md` (Stage 3) in this repository first; this document replaces its
open questions with what we now know and turns them into experiments.

## 1. What is now confirmed

Source: volunteer report, `dangerouslaser/nuclab-reports` issue #6. Decrypt it
with `sh image/tools/get-report.sh 6` (in this repository). The raw kernel log
is at `out/reports/nuclab-*-5bf0c0/raw/dmesg`.

| Fact | Evidence |
|---|---|
| Board NUC7i7BNB (BNH/BNK kits), BIOS BNKBL357.86A.0093 (final) | DMI |
| GPU Kaby Lake GT3, `8086:5927`, DISPLAY_VER 9 | lspci |
| Converter: MegaChips MCDP2800, HW 2.2, FW 1.77 | `AUX B/DDI B/PHY B: DP branch: OUI 00-60-ad dev-ID MC2800 HW-rev 2.2 SW-rev 1.77` |
| Dual-mode ID at I2C 0x40: "DP-HDMI ADAPTOR", id a8, OUI 00-60-ad | i2cdump over AUX B |
| VBT: port B = LSPCON; it appears as connector `DP-1` (not HDMI-A) | `VBT says port B has lspcon` |
| LSPCON runs in PCON mode and reports HDR capability (DPCD 0x70003 bit 0) | `LSPCON capable of HDR` |
| DP link HBR2 x4 (2160000 available); 4K60 RGB8 needs 1782000 | `intel_dp_compute_link_config` |
| HDMI side: TMDS 25–600 MHz, sink YCbCr 4:2:0 allowed, 12 bpc deep colour | `intel_dp_set_edid` / `update_display_info` |
| TV: LG OLED55C3 ("LG TV SSCR2"), direct connection, HF-VSDB present | volunteer answers, ELD |

Not yet captured: the TV's EDID bytes. The survey's EDID copy had a bug (sysfs
reports size 0); it is fixed in commit `ef8d20a` but no image with that fix has
been released. A v0.1.2 survey image fixes it (see §6).

## 2. Why DV cannot work today (code facts)

Pinned kernel: `a90ee4305c4a5df72c11b31dacfdc76e00fcf78a` (7.3-rc6).

1. **Policy excludes the route.** `linux-9900-07` attaches
   `DVBRIDGE_DV_STANDARD_LAB` only in `intel_hdmi_add_properties()` and only for
   `DISPLAY_VER >= 12`. `intel_dv_lab_validate()` rejects `!native_hdmi`
   (`lspcon.active`). On this NUC the port is an LSPCON-backed **DP** connector,
   so neither the property nor the HDMI compute path is ever reached.
2. **LSPCON drops vendor InfoFrames.** `lspcon_write_infoframe()`
   (`intel_lspcon.c:493`) handles exactly two types:
   - AVI → MegaChips DPCD mailbox `0x5C0..0x5DE` + kick-off at `0x5DF`;
   - `HDMI_PACKET_TYPE_GAMUT_METADATA` → the GPU's own GMP DIP via
     `hsw_write_infoframe()`. That is how HDR10 works on LSPCON: the converter
     turns that DP packet into an HDMI DRM InfoFrame.
   Every other type, including `HDMI_INFOFRAME_TYPE_VENDOR`, hits `default:
   return`. `lspcon_infoframes_enabled()`/`lspcon_read_infoframe()` read back
   only AVI and GMP, so a naive VS enable would also trip the state checker.
3. **LSPCON builds its own AVI.** `lspcon_set_infoframes()` builds the AVI
   frame itself, so the DV AVI overrides in `intel_hdmi_compute_avi_infoframe()`
   (RGB, full range, colorimetry none, CTA VIC) do not apply on this path.
4. **No documentation.** Intel (Ville Syrjälä, intel-gfx, 2026-10-19,
   msg386214) on getting a VSIF through an LSPCON: "There are no docs :(".
   He also said he does not think the DP VSC SDP is guaranteed to be converted
   to its InfoFrame counterpart. A NUC8i7BEH (also MC2800) user got 3D frame
   packing from timing alone, without proving any VSIF reached the TV
   (msg386211). Nobody has reported sending an arbitrary VSIF through an
   MCDP2800.

The core question is therefore narrow: **can we make FW 1.77 emit a Dolby VSIF
on its HDMI output, and does it pass the RGB8 tunnel bytes unchanged?**
Everything else (Kodi, renderer, metadata) already works on native HDMI.

## 3. Hypotheses, in order of test

Each one is cheap to test once the lab image exists (§5). Stop at the first
one that works; still run the controls.

- **H1: the converter forwards the GPU's VS DIP.** Enable the transcoder's
  VS DIP (`VIDEO_DIP_ENABLE_VS_HSW`) on the DP port with the Dolby VSIF
  payload, encoded the same way the working GMP/HDR path is encoded. If the
  chip translates DP InfoFrame SDPs generically, which is how GMP→DRM appears
  to work, this is the expected answer.
- **H1b: the same, with the DP "InfoFrame SDP" header form** (HB1 = InfoFrame
  type 0x81, as `intel_dp_hdr_metadata_infoframe_sdp_pack()` does for 0x87).
  Run this only if H1 fails. First establish from the code and bspec exactly
  which bytes the working GMP path puts on the wire, and test the two encodings
  deliberately instead of guessing.
- **H2: the converter forwards the GMP slot verbatim regardless of type.** Put
  the Dolby VSIF into the GMP DIP instead of a DRM InfoFrame. This test is
  ugly but harmless, because it uses only GPU registers.
- **H3: a vendor DPCD mailbox for other InfoFrames.** No address is known. Do
  **not** write to guessed DPCD addresses: MCDP2800 firmware is updated over
  AUX, and a stray write could brick the converter. Permitted: a read-only DPCD
  dump of `0x00500–0x005FF` and `0x70000–0x700FF` for analysis. Reading can
  have side effects on some mailboxes, so read once and log it. Any write
  experiment needs a documented source (MegaChips/Kinetic, Intel Windows
  driver behaviour, or an analyser trace) and the owner's explicit approval.
- **H4: no route exists in FW 1.77.** Record it, keep HDR10 conversion
  (already in the port, and LSPCON HDR10 works) as the NUC7 output, and do not
  expose the DV property on this route.

Controls run on every lab boot:

- **C1 baseline:** 3840x2160@23.976 RGB8 full range with the DV-style AVI
  (RGB, full, VIC 93, colorimetry none) through the MCA mailbox, showing a
  plain pattern with near-black/near-white steps. The TV shows a normal
  picture with correct full range.
- **C2 HDR positive control:** the existing LSPCON HDR10 path with
  `HDR_OUTPUT_METADATA` set. The TV shows its HDR badge. This proves FW 1.77
  forwards the GMP packet on this unit. If C2 fails, H1/H2 conclusions are
  meaningless.

## 4. Success criteria (keep the PLAN.md evidence classes separate)

1. **DV recognition:** the LG C3 enters Dolby Vision. Its picture-mode list
   switches to the Dolby Vision modes, and the info banner or badge shows DV.
2. **Transport correctness:** the image is correct, with no magenta/green
   garbage or flashing. The Standard-DV tunnel carries CRC-protected metadata
   in the pixel LSBs, so a stable DV lock on the reference frame is strong
   evidence that the bytes survived. Add the DP-side check: if the MCDP2800
   advertises `DP_TEST_SINK_MISC` CRC support (DPCD `0x246` bit 5), reuse the
   method in `ps5-libreelec/port/dvcrc.c` to compare the converter's DP RX
   CRC with the framebuffer. Neither check alone covers the HDMI output
   stage; together with a clean DV lock they are adequate. An HDMI analyser
   remains the decisive check if one becomes available.
3. **Lifecycle:** DV→SDR→DV transitions, TV off/on (hotplug), LSPCON resume
   (`intel_lspcon_resume`), and suspend/resume all leave the correct
   InfoFrames. No stale VSIF stays on after DV stops.
4. **Playback qualification**, separate from all of the above: actual Kodi
   playback on KBL GT3 (§7).

## 5. Lab harness: reuse the survey image, not Kodi

The volunteer is remote, so every round trip costs a person's evening. Batch
all hypotheses and controls into **one boot**, with clear prompts.

Build a `dvlab` variant of this repository's USB image (`image/`):

- **Kernel:** build from the LibreELEC port's tree: the same pinned 7.3-rc6,
  the yblod patch series, plus one new lab-only patch (below). Package it with
  the existing UKI pipeline (`image/scripts/build-image.sh`), replacing
  Alpine's `linux-lts`. Keep the module allowlist and the strict depmod check;
  add the new kernel's modules to the QEMU smoke test.
- **Lab patch (not for release):** a debugfs file under the DP connector
  (e.g. `i915_lspcon_dv_lab`) that selects the experiment (`off|h1|h1b|h2`) for
  the next commit. It sets `crtc_state->infoframes` and the DIP enable bits
  accordingly, and extends `lspcon_infoframes_enabled()`/`lspcon_read_infoframe()`
  so the state checker agrees. It also applies the DV AVI overrides in
  `lspcon_set_infoframes()` when the experiment is active, and logs the exact
  DIP bytes written. Gate it behind a module parameter that defaults off.
- **`dvprobe` (C, libdrm atomic):** start from `ps5-libreelec/port/hdrtest.c`
  and `dvcrc.c`.
  - Do a full modeset to 4K23.976 RGB8 with `max bpc`=8, `Broadcast RGB`=Full
    and `Colorspace`=Default.
  - Scan out a static reference frame, select the experiment, and hold it for
    20 s.
  - Restore the original mode. Add a watchdog that restores the mode if the
    program dies (the PLAN.md Stage 2 rules).
  - Ask the volunteer after each step: "Does the TV show Dolby Vision? Is the
    picture correct?"
- **Reference frame:** one packed Standard-DV RGB8 tunnel frame captured from
  the working native-HDMI setup (Geekom IT11 + LG G5) using the port's own
  renderer. Use a self-made, non-copyrighted DV test clip (synthetic pattern
  plus an RPU from `dovi_tool`), never a movie excerpt. Verify the frame
  produces DV on the IT11 before shipping it. Also ship a second frame with
  the metadata deliberately corrupted, as a negative control: the TV must
  **not** enter DV with it.
- **Report:** reuse the survey collector, encryption and upload. Add the
  `dvprobe` transcript, volunteer answers per step, DIP readback, the
  read-only DPCD dumps (H3) and `DP_TEST_SINK` CRC results. Ask for a phone
  photo of the TV's info banner per step, sent separately.
- **Volunteer UX:** the survey's menu, with a new `[D] display experiments`
  entry that runs only when chosen. Never run it automatically at boot.
  Steps are numbered on screen, so photos and answers can be matched.

Run order for the one boot: C1 → C2 → H1 → H1b → H2 → negative control → C1
again (proves restoration). Then 4K59.94 for whichever hypothesis worked
(594 MHz TMDS is within the converter's 600 MHz limit).

## 6. Before the lab image: two cheap steps

1. Release survey v0.1.2 (`ef8d20a`: EDID capture plus summary fix) and ask
   the volunteer for one more 2-minute run to get the LG C3's EDID. Check its
   Dolby VSVDB against `intel_dv_lab_edid()` and the port's v0/v1/v2 parser
   (`linux-9902-hdmi-compatibility.patch`). LG 2023 sets should be v2, but
   verify; do not assume.
2. In the port tree, read `intel_dp.c`'s LSPCON paths
   (`intel_dp_compute_config` HDR/AVI handling, the LSPCON 4:4:4→4:2:0 case
   in `lspcon_set_infoframes()` (around line 569), `intel_lspcon_active()`
   uses near `intel_dp.c:6155`, connector property attachment), and `hsw_dip_data_reg()`/DIP enables for
   DISPLAY_VER 9. Write down which DIP slots a gen9 DDI in DP mode has and
   how their headers go on the wire. This decides how H1/H1b are encoded.

## 7. If a hypothesis works: product integration in the port

Kernel (new patch, e.g. `linux-9930-lspcon-mca-dv.patch`):

- In `intel_lspcon.c`: route `HDMI_INFOFRAME_TYPE_VENDOR` through the proven
  mechanism for MCA only, and add VS to the readout functions. In
  `lspcon_set_infoframes()`, apply the DV AVI overrides (reuse
  `intel_dv_lab_avi_vic()`).
- Attach `DVBRIDGE_DV_STANDARD_LAB` to the **DP** connector only when all of
  these hold: `enable_dv_lab`, `lspcon.active`, vendor MCA, branch dev-ID
  `MC2800`, and FW in an allowlist (start with 1.77; add versions only from
  reports).
- Extend `struct intel_dv_lab_link` with an explicit verified-route flag. Do
  not just drop the `native_hdmi` check: unknown converters and Parade stay
  rejected. Keep every other `intel_dv_lab_validate()` rule (RGB8, full
  range, no HDR blob, progressive CTA timings).
- Confirm that `intel_dv_lab_scanout_check()` and the fastset guard in
  `intel_display.c` see the DV state for a DP encoder. Gen9 has no
  pre/post-CSC LUTs, but legacy gamma, CTM and pipe dithering must be checked
  (`dither_force_disable`).
- Re-emit the VS packet on LSPCON resume and hotplug.

Kodi: `SupportsNativeDVOutput()` is property-based and should work on a DP
connector. Audit the `kodi-999x` patches for HDMI-A connector-type
assumptions (EDID source, diagnostics, output-mode UI). Kodi needs
`HDR_OUTPUT_METADATA`, `max bpc`, `Broadcast RGB` and `Colorspace` on the DP
connector; confirm all four exist there on KBL with an LSPCON.

Docs: update `yblod-engine/docs/intel-dv/HARDWARE.md` condition 2 ("native HDMI
only") to name the verified LSPCON route, and add the NUC7 to `VALIDATION.md`
with only what was physically verified.

Playback qualification (separate gate): KBL GT3 decodes HEVC Main10 in
hardware via VAAPI. Check that Vulkan/libplacebo on gen9 ANV meets the
renderer's subgroup and precision requirements; otherwise the fused path falls
back. Qualify Profile 8.1 → Profile 7 MEL → Profile 7 FEL at 4K23.976, in that
order, reporting frame drops from the existing playback-health log. FEL in real
time on this iGPU is unproven; do not advertise it until measured.

## 8. Guardrails

- No DPCD writes outside the two mailboxes the kernel already uses (AVI
  `0x5C0–0x5DF`) without a documented source and owner approval. GPU DIP
  register experiments are fine.
- The lab patch and debugfs knob never ship in a release build.
- Do not relax eligibility for Parade, unknown OUIs or unlisted firmware.
- Do not treat "TV showed a DV badge" as transport correctness. Report
  recognition, transport, lifecycle and playback separately and say which
  were verified.
- If H1–H2 all fail, write the result up (including the C2 control) in
  `VALIDATION.md` and ship HDR10 conversion as the NUC7 path. Do not keep
  iterating on the volunteer's time without a new, documented hypothesis.

## 9. References

- Survey data: issue #6 in `dangerouslaser/nuclab-reports`. Survey image
  source: this repository, `image/`.
- Kernel: `drivers/gpu/drm/i915/display/intel_lspcon.c` (lines 44–57,
  435–525, 642–669 at the pinned commit), `intel_hdmi.c`
  (`hsw_write_infoframe` line 518; LSPCON hooks around line 3091).
- Port patches: `linux-9900-01`, `-05`, `-07`, `linux-9902`, Kodi `kodi-9990`
  (around line 3287, `SupportsNativeDVOutput`) and `kodi-9995`.
- PS5 precedent (bridge-programmed VSIF and the CRC method):
  `ps5-libreelec/port/add_dv_flava3.py`, `dvcrc.c`, `hdrtest.c`,
  `DV-TESTPLAN.md`. FLAVA3 registers do not transfer.
- intel-gfx thread on LSPCON 3D/VSIF, 2026-10-19:
  https://www.mail-archive.com/intel-gfx@lists.freedesktop.org/msg386211.html
  and msg386214.
