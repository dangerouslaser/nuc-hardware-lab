# NUC Display Lab implementation and handoff plan

## Request and scope

Created 2026-11-07 following research in LibreELEC-yblod. The owner has no
NUC7i7BNH available and wants a simple artifact that another user can test.
This repository is the home for that work. No hardware access, remote host,
volunteer, or GitHub destination has been provided.

Build in two stages:

1. A portable, read-only diagnostic collector for a volunteer's existing Linux
   or LibreELEC installation.
2. A bootable USB display-test image based on LibreELEC, with a small direct
   DRM/KMS test program and experimental kernel support when there is a concrete
   bridge-signaling experiment to run.

Do not build a separate general-purpose distribution. Keep the eventual driver
implementation compatible with the LibreELEC-yblod kernel and patch series.

## Findings and confidence

- The NUC7i7BN family uses an onboard active DP-to-HDMI converter. Current ASUS
  support material calls its external HDMI port HDMI 2.0b; the older Intel
  technical specification calls it HDMI 2.0a.
- MCDP2800 is strongly supported as the expected chip, but the exact volunteer
  unit's bridge identifier, silicon revision and firmware need confirmation.
  Intel's graphics CI inventory reports MC2800 on the sibling NUC7i5BNH; its
  NUC7i7BNH entry has disconnected outputs and does not independently identify
  that unit's bridge.
- LibreELEC-yblod currently limits its Intel DV path to DISPLAY_VER >= 12 and
  excludes active LSPCON conversion. Kaby Lake is outside that supported path.
- In the inspected pinned Linux source, lspcon_write_infoframe() handles AVI
  and the HDR metadata path, but ignores vendor-specific InfoFrames. Removing
  eligibility checks alone cannot produce working Dolby signaling.
- Our PS5 work supplies a useful design precedent: the FLAVA3 bridge is
  programmed directly with a Dolby VSIF and appropriate AVI signaling, with
  byte-preserving RGB transport. The local notes record PS5 Pro/LG B4 success
  at 4K23.976 with Profile 7 FEL and TrueHD. This is recorded prior validation,
  not a test conducted for this repository.
- FLAVA3 registers and control interfaces are not transferable to MCDP2800.
- No verified MCDP2800 arbitrary-VSIF programming interface or working NUC DV
  patch was found. An Intel developer's October 2026 discussion of LSPCON 3D
  signaling explicitly notes missing documentation. That is evidence of an
  interface gap, not proof that Dolby output is impossible.

## Stage 1: hardware survey

Deliver a shell collector with no third-party runtime requirement. Prefer
POSIX shell and support BusyBox/LibreELEC as well as desktop Linux. Missing
optional utilities or permissions must be recorded rather than aborting the
entire report.

Collect:

- OS/kernel and GPU driver versions, GPU PCI identity, and board/product model.
  Avoid collecting system serial numbers or machine IDs by default.
- DRM connector status, modes, raw EDIDs and available atomic properties.
- Relevant kernel messages and available i915 display/debug information.
- Bridge manufacturer/identifier, hardware revision and firmware where the
  existing driver exposes them; explicitly report unknown fields.
- Driver parameters relevant to DV and the availability of the existing
  DVBRIDGE_DV_STANDARD_LAB connector property.
- Optional output from drm_info, modetest, edid-decode and lspci when installed.
  Use query-only invocations. Apply timeouts to potentially blocking commands.
- Volunteer-entered connection description: NUC port, direct TV or AVR path,
  TV model, and any adapters. Do not infer these from EDID alone.

Create a local .tar.gz with a concise summary and raw evidence. Print its path.
Do not upload automatically. Explain that EDIDs and logs may contain display
identifiers or addresses. Prefer a minimal display report over copying Kodi's
entire playback history. Do not claim full anonymization.

Default collection must not modeset, change firmware, write bridge registers,
restart services, or mount filesystems. If debugfs is unavailable, report that
fact and document an optional separate setup step. Do not sweep unknown AUX or
I2C addresses in the survey.

Start by adapting the existing collector, preserving appropriate provenance:

`/Users/bryanhoban/Projects/libreelec-yblod-engine-integration/yblod-engine/tools/dv-diagnostics`

Acceptance:

- Produces a useful report without optional tools or root-only files.
- Handles multiple GPUs/connectors and no connected display.
- Records command failures and tool versions.
- Uses restrictive output permissions and predictable cleanup behavior.
- Has fixture-based checks for collection/parsing and manual shell validation.
- Includes short volunteer instructions and an example report with synthetic
  data, clearly marked as such.

## Stage 2: reproducible USB test image

Use the LibreELEC build system and aligned kernel sources. First inspect its
existing USB boot/install behavior: do not assume the standard image is a
non-installing live environment. Provide an explicitly non-installing test
boot that does not modify internal disks. Document that writing the image
erases the selected USB device.

Include a console menu:

1. Collect hardware report.
2. Run RGB transport test.
3. Run experimental Dolby Vision test (only present when implemented).
4. Export report / shut down.

Use a small direct DRM/KMS program, not Kodi, for initial transport tests.
Include useful diagnostics such as modetest, drm_info and edid-decode subject
to package availability and licensing. Record exact image, kernel, patch and
test-program revisions in every result. No automatic remote access or uploads.

Interactive modesets need a short restore timeout and an independent watchdog
or equivalent recovery mechanism. Test restoration after normal exit, failed
atomic commit, process crash and HDMI unplug. Never launch display experiments
automatically on boot.

A generic RGB pattern is sufficient for baseline mode testing; it is not a
valid Dolby Vision test stream. The DV experiment needs a known-valid packed
test raster with the correct metadata and signaling. Determine how to derive
and validate that fixture using existing project code before distributing it.
Avoid copyrighted movie excerpts in the test image.

## Stage 3: MCDP2800 signaling feasibility and driver work

This is the main unresolved technical dependency, not an established fix.

1. Obtain a volunteer survey confirming bridge and firmware, and establish
   ordinary full-range RGB8 output with a direct TV connection.
2. Find documented or experimentally verified means to emit the required
   Dolby VSIF through the MCDP2800. Do not invent register addresses or assume
   the AVI mailbox accepts arbitrary InfoFrames. DP packet forwarding is also
   only a hypothesis until verified for the actual firmware.
3. Prove signaling at the HDMI receiver before broadly changing eligibility.
   Firmware HDR capability and DV EDID presence are not proof of VSIF support.
4. Add a narrowly scoped experimental i915 DP/LSPCON backend. Expose the DV
   property only for supported, identified routes and validate the Kaby Lake
   scanout path. Retain rejection for unknown converters.
5. Ensure RGB8/full-range byte preservation across GPU and bridge: no dithering,
   LUT/CSC processing, scaling, overlays, or chroma conversion after packing.
6. Program the appropriate AVI and Dolby signaling, coordinate with bridge
   setup, and clear/reapply state correctly on stop, modeset, hotplug and
   suspend/resume. Review failure propagation and atomic-state consistency.
7. Audit userspace property requirements on the DP connector. Existing Kodi
   eligibility is largely property-driven, but requires properties including
   HDR_OUTPUT_METADATA, max bpc, Broadcast RGB and Colorspace.

Start with 3840x2160 at 23.976/24 Hz, then extend to 25/30 and 50/60 only after
link validation. Signal transport success is separate from the NUC's ability
to reconstruct and render real-time FEL content.

Do not treat a generic USB-C-to-HDMI adapter or HDMI firmware update as a
proven workaround. Either introduces capabilities that need verification.
If arbitrary Dolby signaling cannot be implemented, record the limitation
and retain HDR10/SDR fallback rather than enabling a misleading DV option.

## Volunteer protocol and success criteria

First round: connect the onboard HDMI directly to a DV-capable TV, run the
survey, and return the archive plus connection/TV information.

Later rounds: boot the test USB, select an explicitly named experiment,
observe its short test interval, and return the report plus a photo of the
TV signal-information screen and a description of the picture.

Classify evidence separately:

- EDID support: the sink advertises a capability.
- Atomic acceptance: the kernel accepted a requested configuration.
- DV recognition: the TV recognized Dolby signaling.
- Transport correctness: receiver-side pixels/metadata match expectations.
- Playback qualification: actual engine output remains correct and stable.

A Dolby badge alone is not transport correctness. GPU/DP CRC checks alone
cannot establish that the converter's HDMI output preserved bytes. Prefer
receiver diagnostics or an appropriate HDMI analyzer for the decisive check.
Keep unverified outcomes explicitly marked.

Test SDR/HDR10/DV transitions, repeated modesets, hotplug, and audio separately.
The PS5 notes record an AC3/E-AC3 issue under DV; that is a reason to test audio
combinations, not evidence that the NUC has the same bug.

## Local references for the next session

LibreELEC-yblod source:

`/Users/bryanhoban/Projects/libreelec-yblod-engine-integration`

Relevant paths relative to it:

- `yblod-engine/tools/dv-diagnostics`
- `yblod-engine/docs/intel-dv/HARDWARE.md`
- `yblod-engine/docs/intel-dv/DIAGNOSTICS.md`
- `yblod-engine/patches/linux/linux-9900-07-drivers__gpu__drm__i915__display__intel_hdmi.c.patch`
- `yblod-engine/patches/linux/linux-9901-native-hdmi-level-shifter.patch`
- `yblod-engine/patches/linux/linux-9900-01-drivers__gpu__drm__i915__display__intel_display.c.patch`
- `yblod-engine/patches/kodi/kodi-9990-native-dv.patch`
- `packages/linux/package.mk`

The inspected default kernel source was commit
`a90ee4305c4a5df72c11b31dacfdc76e00fcf78a` (labelled 7.3-rc6). Re-check the build
configuration before implementation rather than assuming this stays current.

PS5 precedent:

- `/Users/bryanhoban/Projects/ps5-libreelec/port/PS5-README.md`
- `/Users/bryanhoban/Projects/ps5-libreelec/port/add_dv_flava3.py`
- `/Users/bryanhoban/Projects/ps5-libreelec/port/DV-TESTPLAN.md`
- `/Users/bryanhoban/Projects/ps5-libreelec/port/dvcrc.c`
- `/Users/bryanhoban/Projects/ps5-libreelec/port/patches-7.3/`

## External evidence

- [ASUS NUC7i7BN family display specifications](https://zentalk.asus.com/t5/faq/nuc-multiple-display-configuration-options-for-nuc-kits-nuc7i7bn/ta-p/409387)
- [ASUS NUC HDR guidance and LSPCON topology](https://rog.asus.com/us/support/faq/1052584/)
- [Intel NUC7i5BN/NUC7i7BN technical product specification](https://www.intel.com/content/dam/support/us/en/documents/mini-pcs/nuc-kits/NUC7i5BN_NUC7i7BN_TechProdSpec.pdf)
- [Intel graphics CI hardware inventory](https://intel-gfx-ci.01.org/hardware.html)
- [Pinned Linux LSPCON implementation](https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/drivers/gpu/drm/i915/display/intel_lspcon.c#L493)
- [Intel developer response on missing LSPCON InfoFrame documentation, 2026-10-19](https://www.mail-archive.com/intel-gfx@lists.freedesktop.org/msg386214.html)

## Resume here

Read this plan and the existing collector. Implement Stage 1 in this repository,
with a short volunteer guide and meaningful fixture tests. Do not spend the
first session building an ISO or relaxing the production driver's restrictions.
Request a volunteer report when the collector is ready; bridge-specific work
depends on hardware evidence. Keep the original LibreELEC and PS5 repositories
unchanged unless later work explicitly requires integration there.
