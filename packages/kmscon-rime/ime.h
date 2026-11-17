/*
 * kmscon - librime Input Method Integration
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef KMSCON_IME_H
#define KMSCON_IME_H

#include <libtsm.h>
#include <stdbool.h>
#include <stddef.h>
#include "config.h"
#include "font/font.h"
#include "input/input.h"
#include "render/text.h"
#include "shl/eloop.h"

struct kmscon_ime;

typedef void (*kmscon_ime_commit_cb)(const char *u8, size_t len, void *data);
typedef void (*kmscon_ime_redraw_cb)(void *data);

#ifdef BUILD_ENABLE_IME

int kmscon_ime_new(struct kmscon_ime **out, struct ev_eloop *eloop,
		   const struct kmscon_conf_t *conf,
		   kmscon_ime_commit_cb commit_cb,
		   kmscon_ime_redraw_cb redraw_cb, void *data);
void kmscon_ime_free(struct kmscon_ime *ime);
void kmscon_ime_reset(struct kmscon_ime *ime);

bool kmscon_ime_handle_key(struct kmscon_ime *ime,
			   const struct input_key_event *ev,
			   bool password_prompt);

void kmscon_ime_build_overlay(struct kmscon_ime *ime, struct kmscon_font *font,
			      const struct tsm_screen_attr *def_attr,
			      struct kmscon_text_overlay *out);

#else /* !BUILD_ENABLE_IME */

static inline int kmscon_ime_new(struct kmscon_ime **out,
				 struct ev_eloop *eloop,
				 const struct kmscon_conf_t *conf,
				 kmscon_ime_commit_cb commit_cb,
				 kmscon_ime_redraw_cb redraw_cb, void *data)
{
	(void)eloop;
	(void)conf;
	(void)commit_cb;
	(void)redraw_cb;
	(void)data;
	*out = NULL;
	return 0;
}

static inline void kmscon_ime_free(struct kmscon_ime *ime)
{
	(void)ime;
}

static inline void kmscon_ime_reset(struct kmscon_ime *ime)
{
	(void)ime;
}

static inline bool kmscon_ime_handle_key(struct kmscon_ime *ime,
					 const struct input_key_event *ev,
					 bool password_prompt)
{
	(void)ime;
	(void)ev;
	(void)password_prompt;
	return false;
}

static inline void kmscon_ime_build_overlay(struct kmscon_ime *ime,
					    struct kmscon_font *font,
					    const struct tsm_screen_attr *def_attr,
					    struct kmscon_text_overlay *out)
{
	(void)ime;
	(void)font;
	(void)def_attr;
	out->cells = NULL;
	out->len = 0;
}

#endif /* BUILD_ENABLE_IME */

#endif /* KMSCON_IME_H */
