# Dolby Vision through the MCDP2800 LSPCON: agent plan

Audience: the agent working on the LibreELEC-yblod port
(`/Users/bryanhoban/Projects/libreelec-yblod-engine-integration`).
Written 2026-11-08 after the first successful volunteer survey. Read
`PLAN.md` (Stage 3) in this repository first; this document replaces its
open questions with what we now know and turns them into experiments.

## Status (2026-11-09)

- **Result (report #15, 2026-11-09, v0.3.1-dvlab): DV recognised through
  the MCDP2800 in level-shifter (LS) mode.** This supersedes the "DV stays
  off LSPCON routes" conclusion below for the LS route only; the PCON route
  is still H4. Details and the open questions are in §10, the next round in
  §11.
  - The LS switch went through the standard dual-mode register over AUX
    (I2C 0x40: `0x40/0x41` read `01/01` in PCON mode, `00/00` in LS mode,
    `0x20 = 00` TMDS output on). The EDID came over the LSPCON's
    I2C-over-AUX bridge (lab mode 2), first try.
  - 4K23.976 RGB8 full range (296.7 MHz TMDS) on `HDMI-A-1` / DDI B, with
    the GPU's own AVI and the Dolby VSIF (`Vendor, length 27, Dolby:
    signal 1`) in the native-HDMI layout.
  - Levels: 8/8 near-black and 8/8 near-white squares (full range correct).
    DV reference: Dolby Vision logo, picture = test bars, i.e. the TV
    decoded the RGB8 tunnel, so the pixel bytes survived the LS repeater.
  - **The negative control did not discriminate:** `dv-bad` (every
    metadata CRC broken) also gave the logo and test bars. The C3 appears
    to enter DV on the VSIF alone and to render the tunnel with fallback
    metadata. So recognition and pixel transport are shown; metadata
    integrity is **not** (§8: a DV badge is not transport correctness).
  - Back to PCON by rebind: HBR2 x4 link training passed, registers back
    to `01/01`, volunteer confirmed a normal screen. Each rebind took about
    8-9 s.
  - v0.3.0's "No Signal" (no report survived) is not explained. v0.3.0
    tried GMBUS DDC (mode 1) first; v0.3.1 tried mode 2 first and added
    `video=` and a framebuffer wait, so any of these may be the fix.

- §6.1 done without a volunteer run: the C3's EDID is in report #6
  (`raw/modetest`). The port's `dvbridge_parse_edid()` returns
  `standard-dv`, VSVDB v2, `legacy_vsif=0`, 2160p60 capable.
- §6.2 done: the wire encodings are written down in `image/dvlab/README.md`.
  HDR10 on LSPCON is a DP InfoFrame SDP in the GMP DIP. The transcoder is in
  DP mode, so every DIP's first dword goes out as an SDP header. H1b is
  therefore redefined as an SDP header variant (HB2 = 0x1c), not as the
  native-HDMI packet layout.
- §5: the lab patch, `dvprobe`, the reference and negative frames and the
  `dvlab` image variant are in `image/dvlab/` and `image/rootfs`.

- **Result (report #8, 2026-11-08): H4 for the PCON route.** C1 and C2 pass (full range
  correct; the HDR logo shows, so the GMP SDP is forwarded). H1, H1b and H2
  give no Dolby Vision, and the negative control behaves the same. The DP RX
  CRC equals the framebuffer CRC in every step, and the readback confirms the
  exact DIP bytes. FW 1.77 converts the GMP SDP with type 0x87 but not 0x81,
  and does not forward the VS DIP. 0x5B0-0x5FF NAKs reads. Written up in
  libreelec-yblod `yblod-engine/docs/intel-dv/VALIDATION.md`; DV stays off
  LSPCON routes. The driver work is parked on libreelec-yblod branch
  `feature/nuc7-lspcon-dv` (linux-9930).

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

## 10. The level-shifter route: what is shown and what is open

Evidence: report #15 (issue #15 in `dangerouslaser/nuclab-reports`,
`sh image/tools/get-report.sh 15`), files `dvlab/answers.txt`,
`dvlab/progress.txt`, `dvlab/state.txt` (dual-mode registers and
`i915_display_info` per snapshot), `dvlab/dvprobe.log`, `raw/dmesg`.

Per §4's evidence classes:

| Class | Status on the LS route |
|---|---|
| DV recognition | **Shown** (logo, DV picture), but the TV also shows it for broken metadata |
| Pixel transport | **Shown** by the decoded test bars; no CRC check (the LSPCON has no DP RX in LS mode, so the PCON round's DP_TEST_CRC check does not apply) |
| Metadata integrity | **Open**: the negative control gave the same result |
| Lifecycle | Partly shown: DV → SDR → DV across steps, LS → PCON restore. TV off/on, suspend/resume not tested |
| Playback | Not started |

The two `DVBridge: scanout rejected ... stage=crtc reasons=0x20` errors at
169+24 s and 222+24 s are not a problem: bit 5 at the `crtc` stage is "a
plane other than the primary is on the CRTC" (`linux-9903-diagnostics`).
Both are dvprobe's end-of-step restore while DV is still set. The guard
refuses that commit and the next one turns DV off. No rejection during a
hold.

Limits of this route, from the MCDP28x0 datasheet (Rev B) and i915:

- LS mode repeats AC-coupled TMDS up to 340 Mchar/s (HDMI 1.4b); gen9 HDMI
  stops at 300 MHz. So 4K up to 30 Hz: fine for 4K23.976 film, not for a
  4K60 UI.
- No HDR10 in LS mode on gen9: there is no DRM InfoFrame DIP in HDMI mode.
  HDR10 stays on the PCON route (C2 in report #8).
- The datasheet has no register map. The only mode switch used is the
  standard dual-mode register, which i915 already writes for PCON mode.

Product design question for the port (not for the volunteer): DV playback
needs LS mode, while the 4K60 UI and HDR10 need PCON mode. Today the lab
switches by rebinding i915, which swaps the connector (`DP-1` ↔ `HDMI-A-1`).
A release needs a switch at modeset time on one connector. Options to
assess in the port tree: (a) one DP connector whose LSPCON encoder computes
an HDMI-mode config when the DV property is set; (b) both connectors kept
registered with the inactive one reporting disconnected, plus a hotplug on
switch (Kodi would see an output change on every DV title). (a) is cleaner
and needs the most i915 work; decide only after §11 shows metadata
integrity.

## 11. Next round: v0.4.0-dvlab, NUC7 LS round 2

Released 2026-11-09 as `v0.4.0-dvlab` (steps 1-6 of 11.3; the optional
hotplug step and the picture-mode question are not in it). §11.1 was
skipped at the owner's request: neither `dv-bad` nor the A/B pair has been
checked on the G5, so read a "same" answer for DV-B as inconclusive, not as
a failure. `dv-dmb` uses only the L1 change; the L2 fallback was not built.

Goal: settle metadata integrity on the LS route with one more volunteer
boot, and keep it shorter than v0.3.1. Same kernel and lab patch; only
frames, `dvlab.sh` steps and questions change, unless noted.

### 11.1 Owner pre-work (no volunteer time)

On the IT11 + LG G5 over native HDMI with the port's own lab path:

1. Show `dv-bad`. If the G5 also shows DV with test bars, LG sets accept
   broken metadata and `dv-bad` is useless as a control on LG; keep it in
   the run only for the record. Write the answer down either way.
2. Build the metadata A/B frames (11.2) and check the difference is obvious
   on the G5 in a side-by-side photo. Do not ship them otherwise.
3. `tunnelcheck.py check` must report valid packets for every new frame.

### 11.2 New frames

Same picture (testsrc2 plus a grey ramp and a bright-highlight patch, from
`make-frames.sh`), two valid RPUs from `refclip-gen.json` variants that
differ only in display-management metadata, chosen so that a TV that reads
the metadata must render them differently:

- `dv-dm-a`: L1 `max_pq` matching the content (as `dv-ref`).
- `dv-dm-b`: L1 `max_pq = 4095` (10,000 nits) and `avg_pq` raised, so the
  TV's tone mapping compresses the highlights hard: a visibly darker,
  flatter picture.

If the G5 does not show an obvious difference, try L2 trims (large
`trim_offset`/`trim_slope`) at the C3/G5 target before giving up on this
check. Add both frames to `frames.sha256`.

### 11.3 Steps (all in LS mode 2, 4K23.976 RGB8)

Rebind once into LS mode (mode 2 only; mode 1 only if mode 2 brings up no
connector), then:

1. **LS-levels** as before (full-range control, short).
2. **NOVSIF:** `dv-ref` with `--dv` off (no VSIF). Expected: no logo,
   green/purple noise. Proves the VSIF is what switches the TV, and that
   step 3's bars are DV decoding, not the TV guessing.
3. **DV-A:** `dv-dm-a` with the VSIF. Expected: logo, normal bars.
4. **DV-B:** `dv-dm-b` with the VSIF. Question: "Compared with the last
   picture, was this one darker / brighter / the same?" plus a photo
   request. Darker = the TV used the metadata (integrity shown, given
   `tunnelcheck` validated both frames).
5. **DV-A again:** confirms the change follows the frame, not elapsed time
   or a TV setting.
6. **NEG:** `dv-bad`, kept for comparison with the owner's G5 result.
7. **Hotplug (optional, asked first):** with DV-A shown, "switch the TV off
   and on with its remote"; then ask whether DV came back. Needs the LS
   port's HDMI hotplug path, which the lab patch leaves enabled
   (`hpd_pulse` is only removed for DP).

Then rebind to PCON as now. Per step ask, besides the existing questions,
which picture mode the TV lists (LG: the picture mode menu shows "Dolby
Vision ..." names), since the corner logo can be missed.

### 11.4 Script and harness changes

- `dvlab.sh`: new `step` arguments for "no VSIF" and relative-brightness
  questions; drop the mode-1-first path; keep the live copy on the stick.
- `dvprobe`: no change (`--dv` already selects the VSIF; omitting it gives
  the NOVSIF step).
- `make-frames.sh` / `refclip-gen.json`: the two DM variants.
- Report: `answers.txt` gains `brightness_vs_prev=` per step.

### 11.5 Decision after the round

- DV-B visibly darker, DV-A again back to normal, NOVSIF noisy: metadata
  integrity shown on the LS route. Proceed to the §10 design question and
  a product patch (replacing §7, which assumed a PCON-route VSIF).
- No difference between A and B, but the G5 showed one: the LS route
  carries the picture but the C3 is not using the metadata as sent; stop
  and investigate before any product work.
- NOVSIF also shows a logo: something else is sending a Dolby VSIF; check
  `infoframes enabled` in the dump for that step before anything else.
