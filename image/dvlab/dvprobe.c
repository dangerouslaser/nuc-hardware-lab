// dvprobe: one NUC Display Lab display experiment, then exit.
//
// Sets 3840x2160 (23.976 or 59.94 Hz) RGB8 full range on the connected DP
// connector (the NUC7's LSPCON port), shows a frame, selects an i915 LSPCON
// DV lab experiment through debugfs, records the driver's readback and the
// branch's DP RX CRC, holds the picture, switches the experiment off and
// exits. On exit (normal, crash or SIGKILL from the caller's timeout) the DRM
// file closes and i915 restores the console: that is the restore path.
//
// usage: dvprobe --debugfs DIR [--frame FILE | --pattern levels]
//                [--exp off|avi|h1|h1b|h2] [--hdr] [--hz 24|60]
//                [--secs N] [--log FILE]
//   --frame  raw 3840x2160 XRGB8888 (B,G,R,X bytes), e.g. a DV tunnel frame
//   --hdr    HDR10 control: HDR_OUTPUT_METADATA (PQ) + Colorspace BT2020_RGB
//
// Derived from ps5-libreelec/port/dvcrc.c and hdrtest.c.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define W 3840
#define H 2160

static int fd = -1;
static FILE *logf;
static char labfile[512];
static volatile sig_atomic_t stop;

static void out(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	if (logf) {
		va_start(ap, fmt);
		vfprintf(logf, fmt, ap);
		va_end(ap);
		fflush(logf);
	}
	fflush(stdout);
}

static uint16_t crc16_dp(uint16_t b, uint16_t d)
{
	/* DP 1.4 appendix J: f(x) = x^16 + x^15 + x^2 + 1, MSB first. */
	for (int i = 15; i >= 0; i--) {
		int fb = ((b >> 15) ^ (d >> i)) & 1;
		b <<= 1;
		if (fb)
			b ^= 0x8005;
	}
	return b;
}

static int lab_write(const char *cmd)
{
	int f = open(labfile, O_WRONLY);
	int ret = 0;

	if (f < 0 || write(f, cmd, strlen(cmd)) < 0)
		ret = -errno;
	if (f >= 0)
		close(f);
	out("lab %s: %s\n", cmd, ret ? strerror(-ret) : "ok");
	return ret;
}

static void lab_dump(const char *tag)
{
	char line[512];
	FILE *f = fopen(labfile, "r");

	if (!f) {
		out("[%s] cannot read %s: %s\n", tag, labfile, strerror(errno));
		return;
	}
	while (fgets(line, sizeof(line), f))
		out("[%s] %s", tag, line);
	fclose(f);
}

static uint32_t prop_id(uint32_t obj, uint32_t type, const char *name,
			uint64_t *enum_val, const char *enum_name)
{
	drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
	uint32_t id = 0;

	for (uint32_t i = 0; props && i < props->count_props; i++) {
		drmModePropertyRes *p = drmModeGetProperty(fd, props->props[i]);
		if (p && !strcmp(p->name, name)) {
			id = p->prop_id;
			if (enum_name) {
				int found = 0;
				for (int e = 0; e < p->count_enums; e++)
					if (!strcmp(p->enums[e].name, enum_name)) {
						*enum_val = p->enums[e].value;
						found = 1;
					}
				if (!found)
					id = 0;
			}
		}
		drmModeFreeProperty(p);
	}
	drmModeFreeObjectProperties(props);
	return id;
}

static int add(drmModeAtomicReq *req, uint32_t obj, uint32_t type,
	       const char *name, uint64_t val, const char *enum_name)
{
	uint32_t id = prop_id(obj, type, name, &val, enum_name);

	if (!id) {
		out("note: no property %s%s%s on object %u\n", name,
		    enum_name ? "=" : "", enum_name ? enum_name : "", obj);
		return -1;
	}
	drmModeAtomicAddProperty(req, obj, id, val);
	return 0;
}

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int open_i915(void)
{
	char path[32];

	for (int i = 0; i < 8; i++) {
		snprintf(path, sizeof(path), "/dev/dri/card%d", i);
		int f = open(path, O_RDWR | O_CLOEXEC);
		if (f < 0)
			continue;
		drmVersion *v = drmGetVersion(f);
		int ok = v && !strcmp(v->name, "i915");
		drmFreeVersion(v);
		if (ok) {
			out("device %s\n", path);
			return f;
		}
		close(f);
	}
	return -1;
}

/* Levels pattern for the full-range check: black background with eight
 * squares at codes 4..32 (top), white with eight at 223..251 (bottom), and
 * a mid-grey band. A TV that treats the signal as limited range crushes the
 * dark squares at or below 16 into black. */
static void pattern_levels(uint8_t *px, uint32_t pitch)
{
	for (int y = 0; y < H; y++) {
		uint8_t *row = px + (size_t)y * pitch;
		for (int x = 0; x < W; x++) {
			int v;
			if (y < 720) {
				v = 0;
				if (y >= 240 && y < 480 && x >= 240 && (x - 240) % 420 < 300 && (x - 240) / 420 < 8)
					v = 4 + 4 * ((x - 240) / 420);
			} else if (y < 1440) {
				v = 128;
			} else {
				v = 255;
				if (y >= 1680 && y < 1920 && x >= 240 && (x - 240) % 420 < 300 && (x - 240) / 420 < 8)
					v = 223 + 4 * ((x - 240) / 420);
			}
			row[x * 4 + 0] = v;
			row[x * 4 + 1] = v;
			row[x * 4 + 2] = v;
			row[x * 4 + 3] = 0xff;
		}
	}
}

int main(int argc, char **argv)
{
	const char *frame = NULL, *pattern = "levels", *exp = "off", *debugfs = NULL;
	const char *logpath = NULL;
	int hz = 24, secs = 20, hdr = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--frame") && i + 1 < argc) frame = argv[++i];
		else if (!strcmp(argv[i], "--pattern") && i + 1 < argc) pattern = argv[++i];
		else if (!strcmp(argv[i], "--exp") && i + 1 < argc) exp = argv[++i];
		else if (!strcmp(argv[i], "--debugfs") && i + 1 < argc) debugfs = argv[++i];
		else if (!strcmp(argv[i], "--hz") && i + 1 < argc) hz = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
		else if (!strcmp(argv[i], "--hdr")) hdr = 1;
		else {
			fprintf(stderr, "usage: see the comment at the top of dvprobe.c\n");
			return 2;
		}
	}
	if (logpath)
		logf = fopen(logpath, "a");
	if (!debugfs) {
		out("--debugfs is required\n");
		return 2;
	}
	snprintf(labfile, sizeof(labfile), "%s/i915_lspcon_dv_lab", debugfs);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGHUP, on_signal);
	out("dvprobe: exp=%s hz=%d hdr=%d secs=%d frame=%s\n", exp, hz, hdr, secs,
	    frame ? frame : pattern);

	fd = open_i915();
	if (fd < 0 || drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
	    drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
		out("cannot open i915 with atomic: %s\n", strerror(errno));
		return 1;
	}
	if (drmSetMaster(fd))
		out("note: drmSetMaster: %s\n", strerror(errno));

	drmModeRes *res = drmModeGetResources(fd);
	drmModeConnector *conn = NULL;
	for (int i = 0; res && i < res->count_connectors; i++) {
		conn = drmModeGetConnector(fd, res->connectors[i]);
		if (conn && conn->connection == DRM_MODE_CONNECTED &&
		    conn->connector_type == DRM_MODE_CONNECTOR_DisplayPort)
			break;
		drmModeFreeConnector(conn);
		conn = NULL;
	}
	if (!conn) {
		out("no connected DisplayPort connector (the NUC7 HDMI port is DP-1)\n");
		return 1;
	}

	/* 23.976 / 59.94: the lower clock of the two 3840x2160 modes per rate. */
	drmModeModeInfo *mode = NULL;
	for (int i = 0; i < conn->count_modes; i++) {
		drmModeModeInfo *m = &conn->modes[i];
		if (m->hdisplay == W && m->vdisplay == H && m->vrefresh == (uint32_t)hz &&
		    !(m->flags & DRM_MODE_FLAG_INTERLACE) &&
		    (!mode || m->clock < mode->clock))
			mode = m;
	}
	if (!mode) {
		out("no 3840x2160@%d mode on connector %u\n", hz, conn->connector_id);
		return 1;
	}

	/* Keep the CRTC the console uses. */
	uint32_t crtc_id = 0;
	int crtc_index = 0;
	if (conn->encoder_id) {
		drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
		if (enc)
			crtc_id = enc->crtc_id;
		drmModeFreeEncoder(enc);
	}
	if (!crtc_id)
		crtc_id = res->crtcs[0];
	for (int i = 0; i < res->count_crtcs; i++)
		if (res->crtcs[i] == crtc_id)
			crtc_index = i;

	drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
	uint32_t plane_id = 0;
	for (uint32_t i = 0; pres && i < pres->count_planes && !plane_id; i++) {
		drmModePlane *pl = drmModeGetPlane(fd, pres->planes[i]);
		uint64_t type = 0;
		drmModeObjectProperties *pp = drmModeObjectGetProperties(fd, pl->plane_id, DRM_MODE_OBJECT_PLANE);
		for (uint32_t k = 0; pp && k < pp->count_props; k++) {
			drmModePropertyRes *p = drmModeGetProperty(fd, pp->props[k]);
			if (p && !strcmp(p->name, "type"))
				type = pp->prop_values[k];
			drmModeFreeProperty(p);
		}
		if ((pl->possible_crtcs & (1u << crtc_index)) && type == DRM_PLANE_TYPE_PRIMARY)
			plane_id = pl->plane_id;
		drmModeFreeObjectProperties(pp);
		drmModeFreePlane(pl);
	}
	out("connector %u crtc %u plane %u mode %s %u kHz %u Hz\n", conn->connector_id,
	    crtc_id, plane_id, mode->name, mode->clock, mode->vrefresh);
	if (!plane_id)
		return 1;

	struct drm_mode_create_dumb cd = { .width = W, .height = H, .bpp = 32 };
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
		out("create dumb: %s\n", strerror(errno));
		return 1;
	}
	uint32_t fb_id;
	uint32_t handles[4] = { cd.handle }, pitches[4] = { cd.pitch }, offsets[4] = { 0 };
	if (drmModeAddFB2(fd, W, H, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &fb_id, 0)) {
		out("addfb2: %s\n", strerror(errno));
		return 1;
	}
	struct drm_mode_map_dumb md = { .handle = cd.handle };
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md))
		return 1;
	uint8_t *px = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
	if (px == MAP_FAILED)
		return 1;

	if (frame) {
		FILE *f = fopen(frame, "rb");
		for (int y = 0; f && y < H; y++)
			if (fread(px + (size_t)y * cd.pitch, 4, W, f) != W) {
				out("short frame file %s\n", frame);
				return 1;
			}
		if (!f) {
			out("cannot open %s\n", frame);
			return 1;
		}
		fclose(f);
	} else if (!strcmp(pattern, "levels")) {
		pattern_levels(px, cd.pitch);
	}

	/* Expected DP TEST_CRC of the frame (8 bpc RGB, MSB-aligned). */
	uint16_t crc[3] = { 0, 0, 0 };
	for (int y = 0; y < H; y++) {
		const uint8_t *row = px + (size_t)y * cd.pitch;
		for (int x = 0; x < W; x++) {
			crc[0] = crc16_dp(crc[0], row[x * 4 + 2] << 8);
			crc[1] = crc16_dp(crc[1], row[x * 4 + 1] << 8);
			crc[2] = crc16_dp(crc[2], row[x * 4 + 0] << 8);
		}
	}
	out("expected_crc: r %04x g %04x b %04x\n", crc[0], crc[1], crc[2]);

	uint32_t mode_blob = 0, hdr_blob = 0;
	drmModeCreatePropertyBlob(fd, mode, sizeof(*mode), &mode_blob);
	if (hdr) {
		/* struct hdr_output_metadata: type 0, then hdr_metadata_infoframe:
		 * EOTF 2 (PQ), BT.2020 primaries, D65, 1000/0.005 nits, 1000/400. */
		uint8_t m[32] = { 0 };
		uint16_t v[] = { 35400, 14600, 8500, 39850, 6550, 2300, 15635, 16450,
				 1000, 50, 1000, 400 };
		m[4] = 2; /* eotf */
		m[5] = 0; /* metadata_type */
		memcpy(&m[6], v, sizeof(v));
		/* sizeof(struct hdr_output_metadata) == 32 (u32 alignment). */
		drmModeCreatePropertyBlob(fd, m, sizeof(m), &hdr_blob);
	}

	drmModeAtomicReq *req = drmModeAtomicAlloc();
	uint32_t c = conn->connector_id;
	add(req, c, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", crtc_id, NULL);
	add(req, c, DRM_MODE_OBJECT_CONNECTOR, "max bpc", 8, NULL);
	add(req, c, DRM_MODE_OBJECT_CONNECTOR, "Broadcast RGB", 0, "Full");
	if (hdr) {
		add(req, c, DRM_MODE_OBJECT_CONNECTOR, "Colorspace", 0, "BT2020_RGB");
		add(req, c, DRM_MODE_OBJECT_CONNECTOR, "HDR_OUTPUT_METADATA", hdr_blob, NULL);
	} else {
		add(req, c, DRM_MODE_OBJECT_CONNECTOR, "Colorspace", 0, "Default");
		add(req, c, DRM_MODE_OBJECT_CONNECTOR, "HDR_OUTPUT_METADATA", 0, NULL);
	}
	add(req, crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID", mode_blob, NULL);
	add(req, crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE", 1, NULL);
	add(req, crtc_id, DRM_MODE_OBJECT_CRTC, "GAMMA_LUT", 0, NULL);
	add(req, crtc_id, DRM_MODE_OBJECT_CRTC, "DEGAMMA_LUT", 0, NULL);
	add(req, crtc_id, DRM_MODE_OBJECT_CRTC, "CTM", 0, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", fb_id, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", crtc_id, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X", 0, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y", 0, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W", (uint64_t)W << 16, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H", (uint64_t)H << 16, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X", 0, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y", 0, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W", W, NULL);
	add(req, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H", H, NULL);
	int ret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
	out("commit: %d (%s)\n", ret, ret ? strerror(errno) : "ok");
	drmModeAtomicFree(req);
	if (ret)
		return 1;

	/* Let the converter and TV lock to the new mode before signalling. */
	sleep(3);
	lab_dump("after-modeset");
	int lab_ret = 0;
	if (strcmp(exp, "off"))
		lab_ret = lab_write(exp);
	usleep(500000);
	lab_write("crc");
	lab_dump("experiment");

	struct timespec t0, t;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	do {
		usleep(200000);
		clock_gettime(CLOCK_MONOTONIC, &t);
	} while (!stop && t.tv_sec - t0.tv_sec < secs);
	if (stop)
		out("interrupted\n");

	/* Second CRC sample at the end: the frame is static, so it must match. */
	lab_write("crc");
	lab_dump("end");
	if (strcmp(exp, "off"))
		lab_write("off");
	out("dvprobe: done (lab %s)\n", lab_ret ? "FAILED" : "ok");
	return lab_ret ? 3 : 0;
}
