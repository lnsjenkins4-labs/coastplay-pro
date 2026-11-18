// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PRIVATE PROTOTYPE — NOT FOR DISTRIBUTION.
#include "rgp_chiaki_shim.h"

#include <chiaki/session.h>
#include <chiaki/regist.h>
#include <chiaki/discovery.h>
#include <chiaki/remote/holepunch.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/log.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

// Blob layout (82 bytes): regist_key[16] rp_key[16] rp_key_type[4, LE] mac[6] nickname[32] account_id[8]
#define OFF_REGIST 0
#define OFF_RPKEY 16
#define OFF_KEYTYPE 32
#define OFF_MAC 36
#define OFF_NICK 42
#define OFF_ACCOUNT 74

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static ChiakiLog g_log;

static bool g_debug_log = false;

static rgp_log_sink g_sink = NULL;

void rgp_set_debug_log(bool enabled) { g_debug_log = enabled; }
void rgp_set_log_sink(rgp_log_sink sink) { g_sink = sink; }

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(g_debug_log && (level == CHIAKI_LOG_ERROR || level == CHIAKI_LOG_WARNING))
		fprintf(stderr, "RGPLIB %c %s\n", chiaki_log_level_char(level), msg);
	rgp_log_sink sink = g_sink;
	if(sink) sink(chiaki_log_level_char(level), msg);
}

static void init_once(void)
{
	chiaki_lib_init();
	// Errors and warnings only, and they are discarded: lower levels can contain key material.
	chiaki_log_init(&g_log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO, log_cb, NULL);
}

// ---- registration ---------------------------------------------------------------------------

typedef struct { volatile int done; uint8_t *cred; char *nick; } RegistCtx;

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	RegistCtx *ctx = user;
	if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
	{
		ChiakiRegisteredHost *h = event->registered_host;
		memcpy(ctx->cred + OFF_REGIST, h->rp_regist_key, 16);
		memcpy(ctx->cred + OFF_RPKEY, h->rp_key, 16);
		uint32_t t = h->rp_key_type;
		ctx->cred[OFF_KEYTYPE] = t & 0xff; ctx->cred[OFF_KEYTYPE + 1] = (t >> 8) & 0xff;
		ctx->cred[OFF_KEYTYPE + 2] = (t >> 16) & 0xff; ctx->cred[OFF_KEYTYPE + 3] = (t >> 24) & 0xff;
		memcpy(ctx->cred + OFF_MAC, h->server_mac, 6);
		memcpy(ctx->cred + OFF_NICK, h->server_nickname, 32);
		memcpy(ctx->nick, h->server_nickname, RGP_NICKNAME_SIZE);
		ctx->nick[RGP_NICKNAME_SIZE - 1] = 0;
		ctx->done = 1;
	}
	else
		ctx->done = -1;
}

int rgp_register(const char *host, const uint8_t account_id[8], uint32_t pin,
		uint8_t cred_out[RGP_CRED_SIZE], char nickname_out[RGP_NICKNAME_SIZE], int timeout_seconds)
{
	pthread_once(&g_once, init_once);
	memset(cred_out, 0, RGP_CRED_SIZE);
	memset(nickname_out, 0, RGP_NICKNAME_SIZE);
	memcpy(cred_out + OFF_ACCOUNT, account_id, 8);

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = CHIAKI_TARGET_PS5_1;
	info.host = host;
	info.broadcast = false;
	memcpy(info.psn_account_id, account_id, 8);
	info.pin = pin;

	RegistCtx ctx = { 0, cred_out, nickname_out };
	ChiakiRegist regist;
	if(chiaki_regist_start(&regist, &g_log, &info, regist_cb, &ctx) != CHIAKI_ERR_SUCCESS)
		return -2;
	for(int i = 0; !ctx.done && i < timeout_seconds * 20; i++)
		usleep(50000);
	if(!ctx.done)
		chiaki_regist_stop(&regist);
	chiaki_regist_fini(&regist);
	return ctx.done == 1 ? 0 : -1;
}

// ---- sign-in helper -------------------------------------------------------------------------

int rgp_psn_generate_duid(char *out, size_t out_size)
{
	pthread_once(&g_once, init_once);
	size_t size = out_size;
	return chiaki_holepunch_generate_client_device_uid(out, &size) == CHIAKI_ERR_SUCCESS ? 0 : -1;
}

// ---- wake -----------------------------------------------------------------------------------

int rgp_wake(const char *host, const uint8_t cred[RGP_CRED_SIZE])
{
	pthread_once(&g_once, init_once);
	char key[17];
	memcpy(key, cred + OFF_REGIST, 16);
	key[16] = 0;
	uint64_t credential = strtoull(key, NULL, 16);
	return chiaki_discovery_wakeup(&g_log, NULL, host, credential, true) == CHIAKI_ERR_SUCCESS ? 0 : -1;
}

// ---- session --------------------------------------------------------------------------------

struct rgp_session
{
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	rgp_callbacks cb;
	uint32_t audio_channels, audio_rate;
	char *host;
};

static bool video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frame_recovered;
	rgp_session *s = user;
	if(s->cb.on_video) s->cb.on_video(s->cb.user, buf, buf_size, frames_lost);
	return true;
}

static void audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	rgp_session *s = user;
	s->audio_channels = channels; s->audio_rate = rate;
}

static void audio_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	rgp_session *s = user;
	if(s->cb.on_audio && s->audio_channels)
		s->cb.on_audio(s->cb.user, buf, samples_count, s->audio_channels, s->audio_rate);
}

static int map_quit(ChiakiQuitReason r)
{
	switch(r)
	{
		case CHIAKI_QUIT_REASON_STOPPED:
		case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN: return RGP_QUIT_STOPPED;
		case CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN: return RGP_QUIT_REFUSED;
		case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE: return RGP_QUIT_IN_USE;
		case CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED:
		case CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED:
		case CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED: return RGP_QUIT_UNREACHABLE;
		case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_VERSION_MISMATCH: return RGP_QUIT_VERSION;
		case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED:
		case CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN: return RGP_QUIT_DISCONNECTED;
		default: return RGP_QUIT_OTHER;
	}
}

static void event_cb(ChiakiEvent *event, void *user)
{
	rgp_session *s = user;
	if(!s->cb.on_event) return;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			s->cb.on_event(s->cb.user, RGP_EVENT_CONNECTED, 0, NULL); break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			s->cb.on_event(s->cb.user, RGP_EVENT_LOGIN_PIN_NEEDED, 0, NULL); break;
		case CHIAKI_EVENT_QUIT:
			s->cb.on_event(s->cb.user, RGP_EVENT_QUIT, map_quit(event->quit.reason), chiaki_quit_reason_string(event->quit.reason)); break;
		default: break;
	}
}

static int g_bitrate_kbps = 0;
void rgp_set_bitrate_kbps(int kbps) { g_bitrate_kbps = kbps > 0 ? kbps : 0; }

rgp_session *rgp_session_open(const char *host, const uint8_t cred[RGP_CRED_SIZE], int height, int fps, rgp_callbacks callbacks)
{
	pthread_once(&g_once, init_once);
	rgp_session *s = calloc(1, sizeof(*s));
	if(!s) return NULL;
	s->cb = callbacks;
	s->host = strdup(host);

	ChiakiConnectInfo ci;
	memset(&ci, 0, sizeof(ci));
	ci.ps5 = true;
	ci.host = s->host;
	memcpy(ci.regist_key, cred + OFF_REGIST, sizeof(ci.regist_key));
	memcpy(ci.morning, cred + OFF_RPKEY, sizeof(ci.morning));
	memcpy(ci.psn_account_id, cred + OFF_ACCOUNT, sizeof(ci.psn_account_id));
	ChiakiVideoResolutionPreset res = height >= 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p
		: height >= 720 ? CHIAKI_VIDEO_RESOLUTION_PRESET_720p
		: height >= 540 ? CHIAKI_VIDEO_RESOLUTION_PRESET_540p : CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
	chiaki_connect_video_profile_preset(&ci.video_profile, res, fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
	ci.video_profile.codec = CHIAKI_CODEC_H264;
	if(g_bitrate_kbps > 0) ci.video_profile.bitrate = (unsigned int)g_bitrate_kbps;
	ci.video_profile_auto_downgrade = true;
	ci.audio_video_disabled = CHIAKI_NONE_DISABLED;
	ci.packet_loss_max = 0.05;
	ci.enable_idr_on_fec_failure = true;

	if(chiaki_session_init(&s->session, &ci, &g_log) != CHIAKI_ERR_SUCCESS)
	{
		free(s->host); free(s);
		return NULL;
	}
	chiaki_opus_decoder_init(&s->opus, &g_log);
	chiaki_opus_decoder_set_cb(&s->opus, audio_settings_cb, audio_frame_cb, s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&s->opus, &sink);
	chiaki_session_set_audio_sink(&s->session, &sink);
	chiaki_session_set_video_sample_cb(&s->session, video_cb, s);
	chiaki_session_set_event_cb(&s->session, event_cb, s);

	if(chiaki_session_start(&s->session) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_session_fini(&s->session);
		chiaki_opus_decoder_fini(&s->opus);
		free(s->host); free(s);
		return NULL;
	}
	return s;
}

int rgp_psn_list_ps5(const char *token, rgp_psn_device *out, size_t max, size_t *count)
{
	pthread_once(&g_once, init_once);
	*count = 0;
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t n = 0;
	if(chiaki_holepunch_list_devices(token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &n, &g_log) != CHIAKI_ERR_SUCCESS)
		return -1;
	for(size_t i = 0; i < n && i < max; i++)
	{
		memset(&out[i], 0, sizeof(out[i]));
		memcpy(out[i].name, devices[i].device_name, sizeof(out[i].name) - 1);
		memcpy(out[i].uid, devices[i].device_uid, sizeof(out[i].uid));
		out[i].remote_play_enabled = devices[i].remoteplay_enabled;
		(*count)++;
	}
	if(devices)
		chiaki_holepunch_free_device_list(&devices);
	return 0;
}

rgp_session *rgp_session_open_remote(const char *token, const uint8_t console_uid[32], const uint8_t account_id[8],
		int height, int fps, rgp_callbacks callbacks, int *failed_stage, bool port_guessing)
{
	pthread_once(&g_once, init_once);
	int stage_dummy = 0;
	if(!failed_stage) failed_stage = &stage_dummy;
	*failed_stage = 1;
	ChiakiHolepunchSession hs = chiaki_holepunch_session_init(token, &g_log);
	if(!hs) return NULL;
	if(port_guessing)
	{
		chiaki_holepunch_session_force_port_guessing(hs, true);
		chiaki_holepunch_session_set_port_guessing_ports(hs, 0);   // library defaults
		chiaki_holepunch_session_set_port_guessing_socks(hs, 0);
	}
	chiaki_holepunch_upnp_discover(hs);   // optional help from the router; fine if there is none
	*failed_stage = 2;
	if(chiaki_holepunch_session_create(hs) != CHIAKI_ERR_SUCCESS) goto fail_hs;
	*failed_stage = 3;
	if(holepunch_session_create_offer(hs) != CHIAKI_ERR_SUCCESS) goto fail_hs;
	*failed_stage = 4;
	if(chiaki_holepunch_session_start(hs, console_uid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5) != CHIAKI_ERR_SUCCESS) goto fail_hs;
	*failed_stage = 5;
	if(chiaki_holepunch_session_punch_hole(hs, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL) != CHIAKI_ERR_SUCCESS) goto fail_hs;

	*failed_stage = 6;
	rgp_session *s = calloc(1, sizeof(*s));
	if(!s) goto fail_hs;
	s->cb = callbacks;
	s->host = strdup("0.0.0.0");

	ChiakiConnectInfo ci;
	memset(&ci, 0, sizeof(ci));
	ci.ps5 = true;
	ci.host = s->host;
	ci.holepunch_session = hs;
	memcpy(ci.psn_account_id, account_id, sizeof(ci.psn_account_id));
	ChiakiVideoResolutionPreset res = height >= 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p
		: height >= 720 ? CHIAKI_VIDEO_RESOLUTION_PRESET_720p
		: height >= 540 ? CHIAKI_VIDEO_RESOLUTION_PRESET_540p : CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
	chiaki_connect_video_profile_preset(&ci.video_profile, res, fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
	ci.video_profile.codec = CHIAKI_CODEC_H264;
	if(g_bitrate_kbps > 0) ci.video_profile.bitrate = (unsigned int)g_bitrate_kbps;
	ci.video_profile_auto_downgrade = true;
	ci.audio_video_disabled = CHIAKI_NONE_DISABLED;
	ci.packet_loss_max = 0.05;
	ci.enable_idr_on_fec_failure = true;

	// From here the session owns the PlayStation Network handle and frees it itself.
	if(chiaki_session_init(&s->session, &ci, &g_log) != CHIAKI_ERR_SUCCESS)
	{
		free(s->host); free(s);
		return NULL;
	}
	chiaki_opus_decoder_init(&s->opus, &g_log);
	chiaki_opus_decoder_set_cb(&s->opus, audio_settings_cb, audio_frame_cb, s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&s->opus, &sink);
	chiaki_session_set_audio_sink(&s->session, &sink);
	chiaki_session_set_video_sample_cb(&s->session, video_cb, s);
	chiaki_session_set_event_cb(&s->session, event_cb, s);

	*failed_stage = 7;
	if(chiaki_session_start(&s->session) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_session_fini(&s->session);
		chiaki_opus_decoder_fini(&s->opus);
		free(s->host); free(s);
		return NULL;
	}
	*failed_stage = 0;
	return s;

fail_hs:
	chiaki_holepunch_session_fini(hs);
	return NULL;
}

void rgp_session_set_controller(rgp_session *s, uint32_t buttons, uint8_t l2, uint8_t r2,
		int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y)
{
	if(!s) return;
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	st.buttons = buttons;
	st.l2_state = l2; st.r2_state = r2;
	st.left_x = left_x; st.left_y = left_y; st.right_x = right_x; st.right_y = right_y;
	chiaki_session_set_controller_state(&s->session, &st);
}

void rgp_session_close(rgp_session *s)
{
	if(!s) return;
	chiaki_session_stop(&s->session);
	chiaki_session_join(&s->session);
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	free(s->host);
	free(s);
}
