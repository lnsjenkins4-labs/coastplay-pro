// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PRIVATE PROTOTYPE. Thin C surface over the chiaki-ng library so Swift never sees its headers.
#ifndef RGP_CHIAKI_SHIM_H
#define RGP_CHIAKI_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RGP_CRED_SIZE 82          // opaque pairing blob: keys + console id + account id
#define RGP_NICKNAME_SIZE 32

typedef enum {
	RGP_EVENT_CONNECTED = 1,
	RGP_EVENT_QUIT = 2,            // code = RGP_QUIT_*
	RGP_EVENT_LOGIN_PIN_NEEDED = 3
} rgp_event_type;

typedef enum {
	RGP_QUIT_STOPPED = 0,          // we closed it, or the console shut the session down normally
	RGP_QUIT_REFUSED = 1,          // console reachable but refused the session request
	RGP_QUIT_IN_USE = 2,
	RGP_QUIT_UNREACHABLE = 3,
	RGP_QUIT_VERSION = 4,
	RGP_QUIT_DISCONNECTED = 5,     // stream dropped
	RGP_QUIT_OTHER = 6
} rgp_quit_code;

typedef struct {
	void *user;
	void (*on_event)(void *user, int type, int code, const char *message);
	// One H.264 access unit in Annex-B form.
	void (*on_video)(void *user, const uint8_t *data, size_t size, int frames_lost);
	// Interleaved signed 16-bit PCM.
	void (*on_audio)(void *user, const int16_t *samples, size_t frame_count, uint32_t channels, uint32_t rate);
} rgp_callbacks;

typedef struct rgp_session rgp_session;

// Debug builds only: print the library's error and warning lines (never info/verbose, which can
// contain key material) to the device console.
void rgp_set_debug_log(bool enabled);

// Receives every library log line (level 'E', 'W', 'I'...). The receiver must filter: info
// lines can contain key material and must not be stored unless they match a safe allow-list.
typedef void (*rgp_log_sink)(char level, const char *message);
void rgp_set_log_sink(rgp_log_sink sink);

// Blocking. Returns 0 on success and fills cred_out / nickname_out. pin is the 8-digit Pair Device number.
int rgp_register(const char *host, const uint8_t account_id[8], uint32_t pin,
		uint8_t cred_out[RGP_CRED_SIZE], char nickname_out[RGP_NICKNAME_SIZE], int timeout_seconds);

// Writes a new client device identifier (text) for a PlayStation sign-in. Returns 0 on success.
int rgp_psn_generate_duid(char *out, size_t out_size);

typedef struct {
	char name[32];
	uint8_t uid[32];
	bool remote_play_enabled;
} rgp_psn_device;

// Lists the PS5 consoles on the signed-in account. Blocking (network). Returns 0 on success.
int rgp_psn_list_ps5(const char *token, rgp_psn_device *out, size_t max, size_t *count);

// Opens a session across the internet, brokered by PlayStation Network: PSN introduces the two
// ends, then picture, sound and input travel directly between them. Blocking for up to about a
// minute. On failure returns NULL and sets *failed_stage: 1 start, 2 create, 3 offer,
// 4 reach console, 5 open path, 6-7 session.
rgp_session *rgp_session_open_remote(const char *token, const uint8_t console_uid[32], const uint8_t account_id[8],
		int height, int fps, rgp_callbacks callbacks, int *failed_stage, bool port_guessing);
// port_guessing: for networks that rewrite ports (many mobile networks and hotspots). Opens many
// sockets and advertises a range of likely ports to raise the chance the two ends meet.

// Asks a paired console in rest mode to wake. Returns 0 if the request was sent (not proof it woke).
int rgp_wake(const char *host, const uint8_t cred[RGP_CRED_SIZE]);

// Picture data rate to ask the console for, in kbps, for sessions opened after this call.
// 0 (the default) keeps the engine's own value for the chosen picture size.
void rgp_set_bitrate_kbps(int kbps);

// height: 360, 540, 720 or 1080. fps: 30 or 60. Returns NULL if the session could not be started.
rgp_session *rgp_session_open(const char *host, const uint8_t cred[RGP_CRED_SIZE], int height, int fps, rgp_callbacks callbacks);
void rgp_session_set_controller(rgp_session *s, uint32_t buttons, uint8_t l2, uint8_t r2,
		int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y);
// Stops, waits for the library threads, and frees. No callbacks fire after this returns.
void rgp_session_close(rgp_session *s);

// Button bits for rgp_session_set_controller.
enum {
	RGP_BTN_CROSS = 1 << 0, RGP_BTN_CIRCLE = 1 << 1, RGP_BTN_SQUARE = 1 << 2, RGP_BTN_TRIANGLE = 1 << 3,
	RGP_BTN_LEFT = 1 << 4, RGP_BTN_RIGHT = 1 << 5, RGP_BTN_UP = 1 << 6, RGP_BTN_DOWN = 1 << 7,
	RGP_BTN_L1 = 1 << 8, RGP_BTN_R1 = 1 << 9, RGP_BTN_L3 = 1 << 10, RGP_BTN_R3 = 1 << 11,
	RGP_BTN_OPTIONS = 1 << 12, RGP_BTN_CREATE = 1 << 13, RGP_BTN_TOUCHPAD = 1 << 14, RGP_BTN_PS = 1 << 15
};

#ifdef __cplusplus
}
#endif
#endif
