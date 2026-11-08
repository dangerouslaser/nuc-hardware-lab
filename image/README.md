# USB survey image

A small UEFI-bootable USB image (about 55 MB to download) for volunteers.
It boots straight into a read-only display survey, so no Linux knowledge is
needed. It identifies the NUC's DP-to-HDMI converter (MegaChips MCDP2800 or
not) and collects display diagnostics. The report is then:

1. saved to `reports/` on the stick
2. committed to a private GitHub repo, with an issue opened for it
3. announced through an ntfy push notification

It runs entirely from RAM (Alpine Linux 3.24 userspace, `linux-lts` kernel).
The image contains no SATA, NVMe or eMMC drivers, so it cannot see or modify
the NUC's internal drives.

## What it collects

See `rootfs/usr/lib/nuclab/collect.sh`. It records:

- DMI model, board and BIOS (no serial numbers), `lspci`, kernel version
- the kernel log, booted with `drm.debug=0x4`. This is what logs the converter
  ID line, e.g. `branch: OUI 00-60-ad dev-ID MC2800 HW-rev 2.2 SW-rev 1.66`
- the DP dual-mode adaptor ID at I2C 0x40 on each DP AUX bus: 32 bytes,
  read-only, the same read i915 does itself
- connector status and modes, raw EDIDs (decoded with `di-edid-decode`),
  `modetest -c`, `drm_info`, and i915 debugfs `display_info`, `dmc_info`, `vbt`
  and `dpcd`
- the volunteer's answers: TV model, connection path, notes
- `commands.log`: every command run, with its exit status or why it was skipped

It never changes the display mode or writes to the converter. The only active
step is a connector re-detect, which is equivalent to replugging the cable.

## Building

Requires Docker (Apple Silicon is fine, because the build runs under amd64
emulation).

```sh
sh image/build.sh          # -> out/nuclab-survey.img.gz (+ .sha256)
sh image/test/qemu-smoke.sh  # optional: boots it in QEMU and does a REAL upload
```

The first build creates `image/local.conf`. It is git-ignored and baked into
the image.

| Setting | Purpose |
|---|---|
| `GITHUB_REPO` | Private repo that receives reports (`dangerouslaser/nuclab-reports`) |
| `GITHUB_TOKEN` | Fine-grained token, see below. Empty = no GitHub upload |
| `NTFY_TOPIC` | Random private topic; subscribe at `https://ntfy.sh/<topic>` |
| `FALLBACK_UPLOAD` | `litterbox` (72 h temporary host), `0x0` or `none`; used only if the GitHub upload fails |

A `nuclab.conf` placed on the stick's FAT partition overrides these settings
at boot, so you can change them without rebuilding.

### The GitHub token

Create one at <https://github.com/settings/personal-access-tokens/new>:

- **Repository access:** Only select repositories → `nuclab-reports`
- **Permissions:** Issues → Read and write; Contents → Read and write
- **Expiration:** short (for example 30 days). Revoke it when testing is done.

**Anyone who has the image can extract the token.** At worst they could spam
issues or files in that single private repo. Never use a classic token or your
`gh` login token here.

## Volunteer instructions

Send them the `.img.gz` file and this text:

> 1. Write `nuclab-survey.img.gz` to a USB stick (512 MB or larger) with
>    [balenaEtcher](https://etcher.balena.io/) or Raspberry Pi Imager.
>    **This erases the stick.**
> 2. Plug a network cable into the NUC if possible, and connect its HDMI port
>    directly to the TV. Turn the TV on.
> 3. Insert the stick, power on the NUC and press **F10** for the boot menu.
>    Pick the UEFI USB entry. If it refuses to boot, disable Secure Boot in
>    the BIOS (F2).
> 4. Answer the three optional questions. After about a minute it shows the
>    result and uploads it. Without a network cable it asks for Wi-Fi
>    details, which you can also put in `wifi.txt` on the stick beforehand.
> 5. Press **P** to power off. Nothing on the NUC is changed.
>
> If the upload fails, send me the file in the `reports` folder on the stick.

## Limitations

- UEFI boot only, and the image is unsigned (Secure Boot must be off).
- The kernel's `CONFIG_DRM_DISPLAY_DP_AUX_CHARDEV` is off, so DPCD is read only
  through the kernel log and debugfs, not `/dev/drm_dp_aux*`.
- The QEMU smoke test checks booting, collection, saving and upload. It cannot
  check converter detection, because QEMU has no Intel GPU.
