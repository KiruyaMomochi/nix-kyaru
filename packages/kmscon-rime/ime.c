/*
 * kmscon - librime Input Method Integration
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <rime_api.h>

#include "conf.h"
#include "ime.h"
#include "shl/log.h"

#define LOG_SUBSYSTEM "ime"

#define KMSCON_IME_MAX_CELLS 512
#define KMSCON_IME_MAX_CANDS 10
#define KMSCON_IME_MAX_SCHEMAS 8
#define KMSCON_IME_MAX_SLOTS (KMSCON_IME_MAX_SCHEMAS + 1)
#define KMSCON_IME_TOAST_NS (1100 * 1000 * 1000L)
#define KMSCON_IME_WIDTH_CACHE_SIZE 128

enum {
	RIME_MOD_SHIFT   = (1 << 0),
	RIME_MOD_LOCK    = (1 << 1),
	RIME_MOD_CONTROL = (1 << 2),
	RIME_MOD_ALT     = (1 << 3),
	RIME_MOD_SUPER   = (1 << 26),
};

struct ime_cand {
	char label[16];
	char text[128];
	char comment[64];
};

struct ime_schema_slot {
	char id[64];
	char name[64];
};

struct ime_width_entry {
	uint32_t ch;
	uint8_t width;
};

struct kmscon_ime {
	const struct kmscon_conf_t *conf;
	struct ev_eloop *eloop;
	struct ev_timer *toast_timer;

	kmscon_ime_commit_cb commit_cb;
	kmscon_ime_redraw_cb redraw_cb;
	void *cb_data;

	RimeApi *rime;
	RimeSessionId sid;
	bool enabled;

	bool composing;
	char preedit[256];
	int cursor_pos;
	int sel_start;
	int sel_end;
	int page_no;
	bool is_last_page;
	int highlighted;
	int num_cands;
	struct ime_cand cands[KMSCON_IME_MAX_CANDS];

	char schema_id[64];
	char schema_name[64];
	bool is_simplified;

	/* Slot 0 is English ("EN"); slots 1..slot_count-1 are Rime schemas. */
	unsigned int slot_count;
	struct ime_schema_slot slots[KMSCON_IME_MAX_SLOTS];
	unsigned int mru[KMSCON_IME_MAX_SLOTS];
	bool enum_active;
	unsigned int enum_pos;

	bool toast_visible;

	struct kmscon_font *cached_font;
	struct ime_width_entry width_cache[KMSCON_IME_WIDTH_CACHE_SIZE];

	struct tsm_screen_cell bar[KMSCON_IME_MAX_CELLS];
};

static unsigned int g_rime_refs;
static bool g_rime_setup_done;

static int mkdir_p(const char *dir)
{
	char tmp[PATH_MAX];
	size_t len;
	char *p;

	if (!dir || !*dir)
		return -EINVAL;

	len = strlen(dir);
	if (len >= sizeof(tmp))
		return -ENAMETOOLONG;

	memcpy(tmp, dir, len + 1);
	if (len > 1 && tmp[len - 1] == '/')
		tmp[len - 1] = '\0';

	for (p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = '\0';
			if (mkdir(tmp, 0700) < 0 && errno != EEXIST)
				return -errno;
			*p = '/';
		}
	}
	if (mkdir(tmp, 0700) < 0 && errno != EEXIST)
		return -errno;
	return 0;
}

static int rime_global_acquire(RimeApi *rime, const char *shared_dir, const char *user_dir)
{
	char prebuilt_dir[PATH_MAX];
	char staging_dir[PATH_MAX];
	bool has_prebuilt = false;

	if (g_rime_refs > 0) {
		g_rime_refs++;
		return 0;
	}

	if (!shared_dir || !*shared_dir)
		shared_dir = BUILD_IME_SHARED_DIR;
	if (!user_dir || !*user_dir)
		user_dir = "/var/lib/kmscon/rime";

	if (mkdir_p(user_dir) < 0)
		log_warning("cannot create rime user dir %s", user_dir);

	snprintf(staging_dir, sizeof(staging_dir), "%s/build", user_dir);
	if (mkdir_p(staging_dir) < 0)
		log_warning("cannot create rime staging dir %s", staging_dir);

	snprintf(prebuilt_dir, sizeof(prebuilt_dir), "%s/build", shared_dir);
	if (access(prebuilt_dir, R_OK) == 0)
		has_prebuilt = true;

	RIME_STRUCT(RimeTraits, traits);
	traits.shared_data_dir = shared_dir;
	traits.user_data_dir = user_dir;
	traits.staging_dir = staging_dir;
	traits.prebuilt_data_dir = has_prebuilt ? prebuilt_dir : NULL;
	traits.distribution_name = "kmscon";
	traits.distribution_code_name = "kmscon";
	traits.distribution_version = "10.1.0";
	traits.app_name = "rime.kmscon";
	traits.min_log_level = 2;
	traits.log_dir = "";

	if (!g_rime_setup_done) {
		rime->setup(&traits);
		g_rime_setup_done = true;
	}
	rime->initialize(&traits);

	if (!has_prebuilt) {
		if (rime->start_maintenance(False))
			rime->join_maintenance_thread();
	}

	g_rime_refs = 1;
	return 0;
}

static void rime_global_release(RimeApi *rime)
{
	if (!g_rime_refs || --g_rime_refs > 0)
		return;

	rime->finalize();
}

static void copy_str(char *dst, size_t cap, const char *src)
{
	size_t n;

	if (!cap)
		return;
	if (!src) {
		dst[0] = '\0';
		return;
	}
	n = strlen(src);
	if (n >= cap)
		n = cap - 1;
	memcpy(dst, src, n);
	dst[n] = '\0';
}

static void format_slot_label(const struct kmscon_ime *ime, unsigned int slot,
			      char *buf, size_t cap)
{
	const char *id, *name;
	bool active_slot;
	bool simp;

	if (slot == 0 || slot >= ime->slot_count) {
		copy_str(buf, cap, "EN");
		return;
	}

	id = ime->slots[slot].id;
	name = ime->slots[slot].name;
	active_slot = ime->enabled && strcmp(ime->schema_id, id) == 0;
	simp = active_slot && ime->is_simplified;

	if (strstr(id, "flypy") || strstr(id, "double_pinyin")) {
		copy_str(buf, cap, simp ? "拼 双拼" : "拼 雙拼");
	} else if (strstr(id, "bopomofo")) {
		copy_str(buf, cap, simp ? "注 注音·简" : "注 注音");
	} else if (name[0]) {
		copy_str(buf, cap, name);
	} else {
		copy_str(buf, cap, "中文");
	}
}

static void load_schema_slots(struct kmscon_ime *ime)
{
	RimeSchemaList list = {0};
	unsigned int i;

	ime->slot_count = 1;
	copy_str(ime->slots[0].id, sizeof(ime->slots[0].id), "ascii");
	copy_str(ime->slots[0].name, sizeof(ime->slots[0].name), "EN");

	if (ime->rime->get_schema_list(&list)) {
		for (i = 0; i < list.size && ime->slot_count < KMSCON_IME_MAX_SLOTS; i++) {
			unsigned int s = ime->slot_count++;
			copy_str(ime->slots[s].id, sizeof(ime->slots[s].id),
				 list.list[i].schema_id);
			copy_str(ime->slots[s].name, sizeof(ime->slots[s].name),
				 list.list[i].name);
		}
		ime->rime->free_schema_list(&list);
	}

	if (ime->slot_count == 1 && ime->schema_id[0]) {
		ime->slot_count = 2;
		copy_str(ime->slots[1].id, sizeof(ime->slots[1].id), ime->schema_id);
		copy_str(ime->slots[1].name, sizeof(ime->slots[1].name), ime->schema_name);
	}

	for (i = 0; i < ime->slot_count; i++)
		ime->mru[i] = i;
}

static unsigned int active_slot_index(const struct kmscon_ime *ime)
{
	unsigned int i;

	if (!ime->enabled)
		return 0;
	for (i = 1; i < ime->slot_count; i++) {
		if (strcmp(ime->slots[i].id, ime->schema_id) == 0)
			return i;
	}
	return ime->slot_count > 1 ? 1 : 0;
}

static void promote_mru(struct kmscon_ime *ime, unsigned int slot)
{
	unsigned int pos, i;

	if (slot >= ime->slot_count)
		return;
	for (pos = 0; pos < ime->slot_count; pos++) {
		if (ime->mru[pos] == slot)
			break;
	}
	if (pos == ime->slot_count)
		return;
	for (i = pos; i > 0; i--)
		ime->mru[i] = ime->mru[i - 1];
	ime->mru[0] = slot;
}

static void commit_mru(struct kmscon_ime *ime)
{
	promote_mru(ime, active_slot_index(ime));
	ime->enum_active = false;
	ime->enum_pos = 0;
}

static void arm_toast(struct kmscon_ime *ime)
{
	struct itimerspec spec = {
		.it_interval = {0, 0},
		.it_value = {
			.tv_sec = KMSCON_IME_TOAST_NS / 1000000000L,
			.tv_nsec = KMSCON_IME_TOAST_NS % 1000000000L,
		},
	};

	ime->toast_visible = true;
	if (ime->toast_timer)
		ev_timer_update(ime->toast_timer, &spec);
}

static void cancel_toast(struct kmscon_ime *ime)
{
	if (!ime->toast_visible)
		return;
	ime->toast_visible = false;
	if (ime->toast_timer)
		ev_timer_update(ime->toast_timer, NULL);
}

static void toast_timer_cb(struct ev_timer *timer, uint64_t num, void *data)
{
	struct kmscon_ime *ime = data;

	(void)timer;
	(void)num;
	commit_mru(ime);
	if (!ime->toast_visible)
		return;
	ime->toast_visible = false;
	if (ime->redraw_cb)
		ime->redraw_cb(ime->cb_data);
}

static void sync_status(struct kmscon_ime *ime, bool allow_toast)
{
	char prev_schema[64];
	bool prev_simp = ime->is_simplified;
	bool had_schema = ime->schema_id[0] != '\0';

	copy_str(prev_schema, sizeof(prev_schema), ime->schema_id);

	RIME_STRUCT(RimeStatus, st);
	if (ime->rime->get_status(ime->sid, &st)) {
		copy_str(ime->schema_id, sizeof(ime->schema_id), st.schema_id);
		copy_str(ime->schema_name, sizeof(ime->schema_name), st.schema_name);
		ime->is_simplified = st.is_simplified != False;
		if (ime->enabled && st.is_ascii_mode) {
			ime->enabled = false;
			commit_mru(ime);
			if (allow_toast)
				arm_toast(ime);
		}
		ime->rime->free_status(&st);
	}

	if (allow_toast && had_schema && ime->enabled &&
	    (strcmp(prev_schema, ime->schema_id) != 0 || prev_simp != ime->is_simplified)) {
		commit_mru(ime);
		arm_toast(ime);
	}
}

static void sync_context(struct kmscon_ime *ime)
{
	int i;

	ime->composing = false;
	ime->preedit[0] = '\0';
	ime->cursor_pos = 0;
	ime->sel_start = 0;
	ime->sel_end = 0;
	ime->page_no = 0;
	ime->is_last_page = true;
	ime->highlighted = 0;
	ime->num_cands = 0;

	if (!ime->enabled)
		return;

	RIME_STRUCT(RimeContext, ctx);
	if (!ime->rime->get_context(ime->sid, &ctx))
		return;

	if ((ctx.composition.length > 0 && ctx.composition.preedit &&
	     ctx.composition.preedit[0] != '\0') ||
	    ctx.menu.num_candidates > 0) {
		ime->composing = true;
		copy_str(ime->preedit, sizeof(ime->preedit), ctx.composition.preedit);
		ime->cursor_pos = ctx.composition.cursor_pos;
		ime->sel_start = ctx.composition.sel_start;
		ime->sel_end = ctx.composition.sel_end;
		ime->page_no = ctx.menu.page_no;
		ime->is_last_page = ctx.menu.is_last_page != False;
		ime->highlighted = ctx.menu.highlighted_candidate_index;
		ime->num_cands = ctx.menu.num_candidates;
		if (ime->num_cands > KMSCON_IME_MAX_CANDS)
			ime->num_cands = KMSCON_IME_MAX_CANDS;

		for (i = 0; i < ime->num_cands; i++) {
			if (RIME_PROVIDED(&ctx, select_labels) && ctx.select_labels[i] &&
			    ctx.select_labels[i][0]) {
				copy_str(ime->cands[i].label, sizeof(ime->cands[i].label),
					 ctx.select_labels[i]);
			} else if (ctx.menu.select_keys &&
				   (size_t)i < strlen(ctx.menu.select_keys)) {
				ime->cands[i].label[0] = ctx.menu.select_keys[i];
				ime->cands[i].label[1] = '\0';
			} else {
				snprintf(ime->cands[i].label, sizeof(ime->cands[i].label),
					 "%d", (i + 1) % 10);
			}
			copy_str(ime->cands[i].text, sizeof(ime->cands[i].text),
				 ctx.menu.candidates[i].text);
			copy_str(ime->cands[i].comment, sizeof(ime->cands[i].comment),
				 ctx.menu.candidates[i].comment);
		}
		cancel_toast(ime);
	}

	ime->rime->free_context(&ctx);
}

static void ensure_session(struct kmscon_ime *ime)
{
	if (ime->sid && ime->rime->find_session(ime->sid))
		return;
	ime->sid = ime->rime->create_session();
	if (ime->sid) {
		ime->rime->set_option(ime->sid, "ascii_mode", False);
		sync_status(ime, false);
		if (ime->slot_count == 0)
			load_schema_slots(ime);
	}
}

int kmscon_ime_new(struct kmscon_ime **out, struct ev_eloop *eloop,
		   const struct kmscon_conf_t *conf,
		   kmscon_ime_commit_cb commit_cb,
		   kmscon_ime_redraw_cb redraw_cb, void *data)
{
	struct kmscon_ime *ime;
	RimeApi *rime;
	int ret;

	if (!out || !eloop || !conf)
		return -EINVAL;

	rime = rime_get_api();
	if (!rime)
		return -ENOTSUP;

	ime = calloc(1, sizeof(*ime));
	if (!ime)
		return -ENOMEM;

	ime->conf = conf;
	ime->eloop = eloop;
	ime->commit_cb = commit_cb;
	ime->redraw_cb = redraw_cb;
	ime->cb_data = data;
	ime->rime = rime;
	ime->enabled = false;

	ret = rime_global_acquire(rime, conf->ime_shared_dir, conf->ime_user_dir);
	if (ret) {
		free(ime);
		return ret;
	}

	ret = ev_eloop_new_timer(eloop, &ime->toast_timer, NULL, toast_timer_cb, ime);
	if (ret)
		log_warning("cannot create IME toast timer: %d", ret);

	ensure_session(ime);
	if (ime->slot_count == 0)
		load_schema_slots(ime);
	/* Start in English while keeping the user's primary Rime schema second in MRU. */
	promote_mru(ime, active_slot_index(ime));
	promote_mru(ime, 0);
	log_info("initialized librime session (schema=%s, slots=%u)",
		 ime->schema_id, ime->slot_count);

	*out = ime;
	return 0;
}

void kmscon_ime_free(struct kmscon_ime *ime)
{
	if (!ime)
		return;

	ev_eloop_rm_timer(ime->toast_timer);
	if (ime->sid)
		ime->rime->destroy_session(ime->sid);
	rime_global_release(ime->rime);
	free(ime);
}

void kmscon_ime_reset(struct kmscon_ime *ime)
{
	if (!ime)
		return;

	if (ime->sid)
		ime->rime->clear_composition(ime->sid);
	ime->enabled = false;
	ime->composing = false;
	commit_mru(ime);
	cancel_toast(ime);
}

static void switch_to_slot(struct kmscon_ime *ime, unsigned int slot)
{
	ensure_session(ime);
	if (ime->sid)
		ime->rime->clear_composition(ime->sid);

	if (slot == 0 || slot >= ime->slot_count) {
		ime->enabled = false;
	} else {
		ime->enabled = true;
		if (ime->sid) {
			if (strcmp(ime->schema_id, ime->slots[slot].id) != 0)
				ime->rime->select_schema(ime->sid, ime->slots[slot].id);
			ime->rime->set_option(ime->sid, "ascii_mode", False);
		}
	}
	sync_status(ime, false);
	sync_context(ime);
}

static void step_mru_toggle(struct kmscon_ime *ime)
{
	if (ime->slot_count <= 1)
		return;

	if (!ime->enum_active || !ime->toast_visible) {
		promote_mru(ime, active_slot_index(ime));
		ime->enum_active = true;
		ime->enum_pos = 1;
	} else {
		ime->enum_pos = (ime->enum_pos + 1) % ime->slot_count;
	}

	switch_to_slot(ime, ime->mru[ime->enum_pos]);
	arm_toast(ime);
}

bool kmscon_ime_handle_key(struct kmscon_ime *ime,
			   const struct input_key_event *ev,
			   bool password_prompt)
{
	uint32_t sym;
	int rime_mods = 0;
	Bool eaten;
	bool changed = false;

	if (!ime || !ev)
		return false;

	if (conf_grab_matches(ime->conf->grab_ime_toggle, ev->mods, ev->num_syms, ev->keysyms)) {
		step_mru_toggle(ime);
		if (ime->redraw_cb)
			ime->redraw_cb(ime->cb_data);
		return true;
	}

	if (ev->num_syms != 1)
		return false;

	sym = ev->keysyms[0];

	/* Ignore standalone modifier presses so holding Super doesn't end MRU cycling. */
	switch (sym) {
	case XKB_KEY_Shift_L:
	case XKB_KEY_Shift_R:
	case XKB_KEY_Control_L:
	case XKB_KEY_Control_R:
	case XKB_KEY_Alt_L:
	case XKB_KEY_Alt_R:
	case XKB_KEY_Meta_L:
	case XKB_KEY_Meta_R:
	case XKB_KEY_Super_L:
	case XKB_KEY_Super_R:
	case XKB_KEY_Caps_Lock:
		return false;
	default:
		break;
	}

	/* Any real key press settles the MRU selection and dismisses the switcher toast. */
	if (ime->enum_active || ime->toast_visible) {
		bool had_toast = ime->toast_visible;
		commit_mru(ime);
		cancel_toast(ime);
		if (had_toast && ime->redraw_cb)
			ime->redraw_cb(ime->cb_data);
	}

	if (!ime->enabled || password_prompt) {
		if (password_prompt && ime->composing && ime->sid) {
			ime->rime->clear_composition(ime->sid);
			sync_context(ime);
			if (ime->redraw_cb)
				ime->redraw_cb(ime->cb_data);
		}
		return false;
	}

	/*
	 * When idle (not composing), pass function keys and Ctrl/Alt/Super
	 * shortcuts directly to the terminal except Ctrl+` (Rime switcher).
	 */
	if (!ime->composing) {
		if (ev->mods & (INPUT_ALT_MASK | INPUT_LOGO_MASK))
			return false;
		if ((ev->mods & INPUT_CONTROL_MASK) &&
		    sym != XKB_KEY_grave && sym != XKB_KEY_asciitilde)
			return false;
		if (sym < 0x20 || sym > 0x7e)
			return false;
	} else if (sym >= XKB_KEY_F1 && sym <= XKB_KEY_F12) {
		return false;
	}

	ensure_session(ime);
	if (!ime->sid)
		return false;

	if (ev->mods & INPUT_SHIFT_MASK)
		rime_mods |= RIME_MOD_SHIFT;
	if (ev->mods & INPUT_LOCK_MASK)
		rime_mods |= RIME_MOD_LOCK;
	if (ev->mods & INPUT_CONTROL_MASK)
		rime_mods |= RIME_MOD_CONTROL;
	if (ev->mods & INPUT_ALT_MASK)
		rime_mods |= RIME_MOD_ALT;
	if (ev->mods & INPUT_LOGO_MASK)
		rime_mods |= RIME_MOD_SUPER;

	eaten = ime->rime->process_key(ime->sid, (int)sym, rime_mods);

	RIME_STRUCT(RimeCommit, commit);
	if (ime->rime->get_commit(ime->sid, &commit)) {
		if (commit.text && commit.text[0] && ime->commit_cb) {
			ime->commit_cb(commit.text, strlen(commit.text), ime->cb_data);
			changed = true;
		}
		ime->rime->free_commit(&commit);
	}

	sync_status(ime, true);
	sync_context(ime);

	if (eaten || changed) {
		if (ime->redraw_cb)
			ime->redraw_cb(ime->cb_data);
		return eaten != False;
	}

	return false;
}

static uint32_t utf8_next(const char **p, const char *end)
{
	const unsigned char *s = (const unsigned char *)*p;
	size_t rem = (size_t)(end - *p);
	uint32_t ch;

	if (rem == 0)
		return 0;

	if (s[0] < 0x80) {
		*p += 1;
		return s[0];
	}
	if ((s[0] & 0xe0) == 0xc0 && rem >= 2 && (s[1] & 0xc0) == 0x80) {
		ch = ((uint32_t)(s[0] & 0x1f) << 6) | (uint32_t)(s[1] & 0x3f);
		if (ch >= 0x80) {
			*p += 2;
			return ch;
		}
	} else if ((s[0] & 0xf0) == 0xe0 && rem >= 3 &&
		   (s[1] & 0xc0) == 0x80 && (s[2] & 0xc0) == 0x80) {
		ch = ((uint32_t)(s[0] & 0x0f) << 12) |
		     ((uint32_t)(s[1] & 0x3f) << 6) |
		     (uint32_t)(s[2] & 0x3f);
		if (ch >= 0x800 && (ch < 0xd800 || ch > 0xdfff)) {
			*p += 3;
			return ch;
		}
	} else if ((s[0] & 0xf8) == 0xf0 && rem >= 4 &&
		   (s[1] & 0xc0) == 0x80 && (s[2] & 0xc0) == 0x80 &&
		   (s[3] & 0xc0) == 0x80) {
		ch = ((uint32_t)(s[0] & 0x07) << 18) |
		     ((uint32_t)(s[1] & 0x3f) << 12) |
		     ((uint32_t)(s[2] & 0x3f) << 6) |
		     (uint32_t)(s[3] & 0x3f);
		if (ch >= 0x10000 && ch <= 0x10ffff) {
			*p += 4;
			return ch;
		}
	}

	*p += 1;
	return TSM_UCS4_REPLACEMENT;
}

static unsigned int glyph_width(struct kmscon_ime *ime, struct kmscon_font *font, uint32_t ch)
{
	unsigned int w;
	unsigned int slot;
	struct kmscon_font_attr fattr = {0};
	struct kmscon_glyph *glyph;

	if (ch >= 0x20 && ch <= 0x7e)
		return 1;
	if (kmscon_font_blocks_has_glyph(ch))
		return 1;

	w = tsm_ucs4_get_width(ch);
	if (w == 0)
		return 0;
	if (w >= 2)
		return 2;
	if (!font)
		return 1;

	if (ime->cached_font != font) {
		memset(ime->width_cache, 0, sizeof(ime->width_cache));
		ime->cached_font = font;
	}

	slot = ch & (KMSCON_IME_WIDTH_CACHE_SIZE - 1);
	if (ime->width_cache[slot].ch == ch && ime->width_cache[slot].width != 0)
		return ime->width_cache[slot].width;

	glyph = kmscon_font_render(font, &fattr, ch);
	if (glyph) {
		w = kmscon_glyph_cwidth(glyph);
		free(glyph);
	}
	ime->width_cache[slot].ch = ch;
	ime->width_cache[slot].width = (uint8_t)w;
	return w;
}

static struct tsm_screen_color rgb(uint8_t r, uint8_t g, uint8_t b)
{
	struct tsm_screen_color c = { .r = r, .g = g, .b = b };
	return c;
}

static struct tsm_screen_color mix_rgb(struct tsm_screen_color a,
				       struct tsm_screen_color b,
				       unsigned int weight_b_pct)
{
	unsigned int wa = 100 - weight_b_pct;

	return rgb((uint8_t)((a.r * wa + b.r * weight_b_pct) / 100),
		   (uint8_t)((a.g * wa + b.g * weight_b_pct) / 100),
		   (uint8_t)((a.b * wa + b.b * weight_b_pct) / 100));
}

struct ime_theme {
	struct tsm_screen_color panel_bg;
	struct tsm_screen_color fg;
	struct tsm_screen_color muted_fg;
	struct tsm_screen_color preedit_fg;
	struct tsm_screen_color cursor_fg;
	struct tsm_screen_color sel_bg;
	struct tsm_screen_color sel_fg;
};

static void resolve_theme(const struct kmscon_conf_t *conf,
			  const struct tsm_screen_attr *def_attr,
			  struct ime_theme *t)
{
	bool custom = conf && (!conf->palette || strcmp(conf->palette, "custom") == 0);

	if (custom) {
		const uint8_t (*p)[3] = conf->custom_palette;
		struct tsm_screen_color blk = rgb(p[TSM_COLOR_BLACK][0],
						  p[TSM_COLOR_BLACK][1],
						  p[TSM_COLOR_BLACK][2]);
		struct tsm_screen_color dg = rgb(p[TSM_COLOR_DARK_GREY][0],
						 p[TSM_COLOR_DARK_GREY][1],
						 p[TSM_COLOR_DARK_GREY][2]);
		struct tsm_screen_color lg = rgb(p[TSM_COLOR_LIGHT_GREY][0],
						 p[TSM_COLOR_LIGHT_GREY][1],
						 p[TSM_COLOR_LIGHT_GREY][2]);
		struct tsm_screen_color mag = rgb(p[TSM_COLOR_MAGENTA][0],
						  p[TSM_COLOR_MAGENTA][1],
						  p[TSM_COLOR_MAGENTA][2]);

		t->panel_bg = mix_rgb(blk, dg, 22);
		t->fg = rgb(p[TSM_COLOR_FOREGROUND][0],
			    p[TSM_COLOR_FOREGROUND][1],
			    p[TSM_COLOR_FOREGROUND][2]);
		t->muted_fg = mix_rgb(dg, lg, 42);
		t->preedit_fg = rgb(p[TSM_COLOR_LIGHT_MAGENTA][0],
				    p[TSM_COLOR_LIGHT_MAGENTA][1],
				    p[TSM_COLOR_LIGHT_MAGENTA][2]);
		t->cursor_fg = rgb(p[TSM_COLOR_LIGHT_CYAN][0],
				   p[TSM_COLOR_LIGHT_CYAN][1],
				   p[TSM_COLOR_LIGHT_CYAN][2]);
		t->sel_bg = mix_rgb(t->panel_bg, mag, 40);
		t->sel_fg = rgb(p[TSM_COLOR_WHITE][0],
				p[TSM_COLOR_WHITE][1],
				p[TSM_COLOR_WHITE][2]);
	} else {
		struct tsm_screen_color bg = def_attr
			? rgb(def_attr->br, def_attr->bg, def_attr->bb)
			: rgb(22, 16, 20);
		struct tsm_screen_color fg = def_attr
			? rgb(def_attr->fr, def_attr->fg, def_attr->fb)
			: rgb(226, 214, 220);
		struct tsm_screen_color accent = rgb(176, 110, 140);

		t->panel_bg = mix_rgb(bg, fg, 12);
		t->fg = fg;
		t->muted_fg = mix_rgb(t->panel_bg, fg, 50);
		t->preedit_fg = mix_rgb(fg, accent, 45);
		t->cursor_fg = fg;
		t->sel_bg = mix_rgb(t->panel_bg, accent, 42);
		t->sel_fg = fg;
	}
}

static bool push_cell_ch(struct kmscon_ime *ime, struct kmscon_font *font,
			 unsigned int *pos, uint32_t ch,
			 struct tsm_screen_color fg,
			 struct tsm_screen_color bg,
			 tsm_screen_attr2_t attr2)
{
	unsigned int w = glyph_width(ime, font, ch);

	if (w == 0)
		return true;
	if (*pos + w > KMSCON_IME_MAX_CELLS)
		return false;

	ime->bar[*pos].ch = ch;
	ime->bar[*pos].fg = fg;
	ime->bar[*pos].bg = bg;
	ime->bar[*pos].attr2 = attr2;
	if (w == 2) {
		ime->bar[*pos + 1].ch = 0;
		ime->bar[*pos + 1].fg = fg;
		ime->bar[*pos + 1].bg = bg;
		ime->bar[*pos + 1].attr2 = attr2;
	}
	*pos += w;
	return true;
}

static void push_utf8(struct kmscon_ime *ime, struct kmscon_font *font,
		      unsigned int *pos, const char *s,
		      struct tsm_screen_color fg,
		      struct tsm_screen_color bg,
		      tsm_screen_attr2_t attr2)
{
	const char *p, *end;

	if (!s || !*s)
		return;
	p = s;
	end = s + strlen(s);
	while (p < end) {
		uint32_t ch = utf8_next(&p, end);
		if (!push_cell_ch(ime, font, pos, ch, fg, bg, attr2))
			break;
	}
}

void kmscon_ime_build_overlay(struct kmscon_ime *ime, struct kmscon_font *font,
			      const struct tsm_screen_attr *def_attr,
			      struct kmscon_text_overlay *out)
{
	struct ime_theme th;
	tsm_screen_attr2_t plain = { .u8 = 0 };
	tsm_screen_attr2_t bold = { .u8 = 0 };
	unsigned int len = 0;
	int i;

	out->cells = NULL;
	out->len = 0;

	if (!ime || (!ime->composing && !ime->toast_visible))
		return;

	resolve_theme(ime->conf, def_attr, &th);
	bold.bold = 1;

	if (!ime->composing && ime->toast_visible) {
		unsigned int cur = active_slot_index(ime);
		unsigned int s;

		for (s = 0; s < ime->slot_count; s++) {
			char label[64];
			bool sel = (s == cur);
			struct tsm_screen_color bg = sel ? th.sel_bg : th.panel_bg;
			struct tsm_screen_color fg = sel ? th.sel_fg : th.muted_fg;
			tsm_screen_attr2_t a = sel ? bold : plain;

			format_slot_label(ime, s, label, sizeof(label));
			push_cell_ch(ime, font, &len, ' ', fg, bg, plain);
			push_utf8(ime, font, &len, label, fg, bg, a);
			push_cell_ch(ime, font, &len, ' ', fg, bg, plain);
		}

		out->cells = ime->bar;
		out->len = len;
		return;
	}

	push_cell_ch(ime, font, &len, ' ', th.fg, th.panel_bg, plain);

	if (ime->preedit[0]) {
		const char *p = ime->preedit;
		const char *end = p + strlen(p);
		int pre_len = (int)(end - p);
		bool drew_cursor = false;

		while (p < end) {
			int off = (int)(p - ime->preedit);
			tsm_screen_attr2_t a = plain;
			uint32_t ch;

			if (!drew_cursor && off >= ime->cursor_pos) {
				push_cell_ch(ime, font, &len, FONT_VBAR,
					     th.cursor_fg, th.panel_bg, plain);
				drew_cursor = true;
			}
			if (ime->sel_end < pre_len && off >= ime->sel_start && off < ime->sel_end)
				a.underline = 1;

			ch = utf8_next(&p, end);
			if (!push_cell_ch(ime, font, &len, ch, th.preedit_fg, th.panel_bg, a))
				break;
		}
		if (!drew_cursor)
			push_cell_ch(ime, font, &len, FONT_VBAR, th.cursor_fg, th.panel_bg, plain);

		if (ime->num_cands > 0) {
			push_cell_ch(ime, font, &len, ' ', th.muted_fg, th.panel_bg, plain);
			push_cell_ch(ime, font, &len, 0x2502, th.muted_fg, th.panel_bg, plain);
		}
	}

	for (i = 0; i < ime->num_cands; i++) {
		bool sel = (i == ime->highlighted);
		struct tsm_screen_color bg = sel ? th.sel_bg : th.panel_bg;
		struct tsm_screen_color lfg = sel ? th.preedit_fg : th.muted_fg;
		struct tsm_screen_color tfg = sel ? th.sel_fg : th.fg;
		tsm_screen_attr2_t ta = sel ? bold : plain;

		if (i > 0 || ime->preedit[0])
			push_cell_ch(ime, font, &len, ' ', th.fg, th.panel_bg, plain);
		if (sel)
			push_cell_ch(ime, font, &len, ' ', tfg, bg, plain);

		push_utf8(ime, font, &len, ime->cands[i].label, lfg, bg, plain);
		push_cell_ch(ime, font, &len, '.', lfg, bg, plain);
		push_utf8(ime, font, &len, ime->cands[i].text, tfg, bg, ta);

		if (ime->cands[i].comment[0]) {
			push_cell_ch(ime, font, &len, ' ', th.muted_fg, bg, plain);
			push_utf8(ime, font, &len, ime->cands[i].comment, th.muted_fg, bg, plain);
		}
		if (sel)
			push_cell_ch(ime, font, &len, ' ', tfg, bg, plain);
	}

	if (ime->num_cands > 0 && (ime->page_no > 0 || !ime->is_last_page)) {
		push_cell_ch(ime, font, &len, ' ', th.muted_fg, th.panel_bg, plain);
		if (ime->page_no > 0)
			push_cell_ch(ime, font, &len, '<', th.muted_fg, th.panel_bg, plain);
		if (!ime->is_last_page)
			push_cell_ch(ime, font, &len, '>', th.muted_fg, th.panel_bg, plain);
	}

	push_cell_ch(ime, font, &len, ' ', th.fg, th.panel_bg, plain);

	out->cells = ime->bar;
	out->len = len;
}
