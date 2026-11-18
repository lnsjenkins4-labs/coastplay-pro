// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// PRIVATE FEASIBILITY PROTOTYPE — NOT FOR DISTRIBUTION.
// Links the AGPL chiaki-ng library, so this file is AGPL too. It exists only to answer
// "can we get live video, audio and input from the owner's PS5?" on a Mac.
//
//   rgp-harness register <host> <account-id-base64> [pin]   pair; saves keys in the macOS Keychain
//   rgp-harness wake <host>                                  wake a paired console from rest mode
//   rgp-harness stream <host> [--seconds N] [--view] [--record DIR] [--tap a,b,c] [--login-pin N]
//   rgp-harness forget <host>                                delete the saved pairing
//
// Nothing is recorded unless --record is given. Secrets are never printed.

#include <chiaki/session.h>
#include <chiaki/regist.h>
#include <chiaki/discovery.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/base64.h>
#include <chiaki/log.h>

#include <Security/Security.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>
#include <sys/time.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define KEYCHAIN_SERVICE "rgp-prototype.ps5-pairing"

typedef struct {
	char regist_key[CHIAKI_SESSION_AUTH_SIZE];
	uint8_t rp_key[0x10];
	uint32_t rp_key_type;
	uint8_t server_mac[6];
	char nickname[0x20];
	uint8_t account_id[CHIAKI_PSN_ACCOUNT_ID_SIZE];
} Cred;

static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int s) { (void)s; g_stop = 1; }

static double now_s(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

// ---- Keychain ----------------------------------------------------------------------------

static void cred_delete(const char *host)
{
	SecKeychainItemRef item = NULL;
	if(SecKeychainFindGenericPassword(NULL, (UInt32)strlen(KEYCHAIN_SERVICE), KEYCHAIN_SERVICE,
			(UInt32)strlen(host), host, NULL, NULL, &item) == errSecSuccess && item)
	{
		SecKeychainItemDelete(item);
		CFRelease(item);
	}
}

static bool cred_save(const char *host, const Cred *cred)
{
	cred_delete(host);
	return SecKeychainAddGenericPassword(NULL, (UInt32)strlen(KEYCHAIN_SERVICE), KEYCHAIN_SERVICE,
			(UInt32)strlen(host), host, (UInt32)sizeof(*cred), cred, NULL) == errSecSuccess;
}

static bool cred_load(const char *host, Cred *cred)
{
	UInt32 len = 0; void *data = NULL;
	OSStatus st = SecKeychainFindGenericPassword(NULL, (UInt32)strlen(KEYCHAIN_SERVICE), KEYCHAIN_SERVICE,
			(UInt32)strlen(host), host, &len, &data, NULL);
	if(st != errSecSuccess || !data) return false;
	bool ok = len == sizeof(*cred);
	if(ok) memcpy(cred, data, sizeof(*cred));
	SecKeychainItemFreeContent(NULL, data);
	return ok;
}

// ---- Logging (info and above only; debug/verbose levels can hexdump key material) ----------

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	fprintf(stderr, "[lib %c] %s\n", chiaki_log_level_char(level), msg);
}

// ---- register ----------------------------------------------------------------------------

static volatile int g_regist_done = 0; // 1 ok, -1 failed
static Cred g_regist_cred;

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	(void)user;
	if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
	{
		ChiakiRegisteredHost *h = event->registered_host;
		memcpy(g_regist_cred.regist_key, h->rp_regist_key, sizeof(g_regist_cred.regist_key));
		memcpy(g_regist_cred.rp_key, h->rp_key, sizeof(g_regist_cred.rp_key));
		g_regist_cred.rp_key_type = h->rp_key_type;
		memcpy(g_regist_cred.server_mac, h->server_mac, 6);
		memcpy(g_regist_cred.nickname, h->server_nickname, sizeof(g_regist_cred.nickname));
		g_regist_done = 1;
	}
	else
		g_regist_done = -1;
}

static int cmd_register(ChiakiLog *log, const char *host, const char *account_b64, const char *pin_arg)
{
	ChiakiRegistInfo info = {0};
	info.target = CHIAKI_TARGET_PS5_1;
	info.host = host;
	info.broadcast = false;
	size_t id_size = sizeof(info.psn_account_id);
	if(chiaki_base64_decode(account_b64, strlen(account_b64), info.psn_account_id, &id_size) != CHIAKI_ERR_SUCCESS
		|| id_size != CHIAKI_PSN_ACCOUNT_ID_SIZE)
	{
		fprintf(stderr, "Account ID must be the base64 form of 8 bytes (12 characters ending in '=').\n");
		return 2;
	}
	char pin_buf[32] = {0};
	if(pin_arg) snprintf(pin_buf, sizeof(pin_buf), "%s", pin_arg);
	else
	{
		printf("8-digit number from PS5 Settings > System > Remote Play > Link Device: ");
		fflush(stdout);
		if(!fgets(pin_buf, sizeof(pin_buf), stdin)) return 2;
	}
	char digits[16] = {0}; size_t n = 0;
	for(char *p = pin_buf; *p && n < 8; p++) if(*p >= '0' && *p <= '9') digits[n++] = *p;
	if(n != 8) { fprintf(stderr, "The PIN must be 8 digits.\n"); return 2; }
	info.pin = (uint32_t)strtoul(digits, NULL, 10);

	memcpy(g_regist_cred.account_id, info.psn_account_id, sizeof(g_regist_cred.account_id));
	ChiakiRegist regist;
	ChiakiErrorCode err = chiaki_regist_start(&regist, log, &info, regist_cb, NULL);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "Could not start registration: %s\n", chiaki_error_string(err)); return 1; }
	double deadline = now_s() + 30;
	while(!g_regist_done && !g_stop && now_s() < deadline) usleep(50000);
	if(!g_regist_done) chiaki_regist_stop(&regist);
	chiaki_regist_fini(&regist);

	if(g_regist_done != 1)
	{
		printf("RESULT register: FAILED (console rejected it, PIN expired, or no answer)\n");
		return 1;
	}
	if(!cred_save(host, &g_regist_cred))
	{
		printf("RESULT register: paired, but saving to the Keychain FAILED\n");
		return 1;
	}
	printf("RESULT register: OK — paired with \"%.*s\"; keys saved in the macOS Keychain (not shown)\n",
		(int)sizeof(g_regist_cred.nickname), g_regist_cred.nickname);
	return 0;
}

// ---- wake --------------------------------------------------------------------------------

static int cmd_wake(ChiakiLog *log, const char *host)
{
	Cred cred;
	if(!cred_load(host, &cred)) { fprintf(stderr, "No saved pairing for %s. Run register first.\n", host); return 2; }
	char key[CHIAKI_SESSION_AUTH_SIZE + 1] = {0};
	memcpy(key, cred.regist_key, CHIAKI_SESSION_AUTH_SIZE);
	uint64_t credential = strtoull(key, NULL, 16);
	ChiakiErrorCode err = chiaki_discovery_wakeup(log, NULL, host, credential, true);
	printf("RESULT wake: %s\n", err == CHIAKI_ERR_SUCCESS ? "wake-up request sent (allow ~15 s)" : chiaki_error_string(err));
	return err == CHIAKI_ERR_SUCCESS ? 0 : 1;
}

// ---- stream ------------------------------------------------------------------------------

typedef struct {
	ChiakiSession session;
	volatile int connected, quit;
	volatile unsigned long video_frames, video_bytes, frames_lost, audio_frames, audio_samples, rumble_events;
	unsigned long total_video_frames, total_audio_frames;
	uint32_t audio_rate, audio_channels;
	FILE *video_out, *audio_out;       // --record
	FILE *video_view, *audio_view;     // --view (ffplay pipes)
	const char *login_pin;
} Stream;

static bool video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frame_recovered;
	Stream *s = user;
	s->video_frames++; s->video_bytes += buf_size; s->total_video_frames++;
	if(frames_lost > 0) s->frames_lost += (unsigned long)frames_lost;
	if(s->video_out) fwrite(buf, 1, buf_size, s->video_out);
	if(s->video_view) { fwrite(buf, 1, buf_size, s->video_view); fflush(s->video_view); }
	return true;
}

static void audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	Stream *s = user;
	s->audio_channels = channels; s->audio_rate = rate;
	printf("EVENT audio format: %u channels, %u Hz\n", channels, rate);
}

static void audio_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	Stream *s = user;
	s->audio_frames++; s->total_audio_frames++; s->audio_samples += samples_count;
	size_t bytes = samples_count * (s->audio_channels ? s->audio_channels : 2) * sizeof(int16_t);
	if(s->audio_out) fwrite(buf, 1, bytes, s->audio_out);
	if(s->audio_view) { fwrite(buf, 1, bytes, s->audio_view); fflush(s->audio_view); }
}

static void event_cb(ChiakiEvent *event, void *user)
{
	Stream *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			s->connected = 1; printf("EVENT connected\n"); break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			if(s->login_pin && !event->login_pin_request.pin_incorrect)
				chiaki_session_set_login_pin(&s->session, (const uint8_t *)s->login_pin, strlen(s->login_pin));
			else
			{
				printf("EVENT console asks for its login passcode%s — rerun with --login-pin NNNN\n",
					event->login_pin_request.pin_incorrect ? " (the one given was wrong)" : "");
				s->quit = 1;
			}
			break;
		case CHIAKI_EVENT_RUMBLE: s->rumble_events++; break;
		case CHIAKI_EVENT_QUIT:
			printf("EVENT session ended: %s%s%s\n", chiaki_quit_reason_string(event->quit.reason),
				event->quit.reason_str ? " — " : "", event->quit.reason_str ? event->quit.reason_str : "");
			s->quit = 1; break;
		default: break;
	}
	fflush(stdout);
}

static uint32_t button_from_name(const char *n)
{
	if(!strcmp(n, "up")) return CHIAKI_CONTROLLER_BUTTON_DPAD_UP;
	if(!strcmp(n, "down")) return CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN;
	if(!strcmp(n, "left")) return CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT;
	if(!strcmp(n, "right")) return CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT;
	if(!strcmp(n, "cross")) return CHIAKI_CONTROLLER_BUTTON_CROSS;
	if(!strcmp(n, "circle")) return CHIAKI_CONTROLLER_BUTTON_MOON;
	if(!strcmp(n, "square")) return CHIAKI_CONTROLLER_BUTTON_BOX;
	if(!strcmp(n, "triangle")) return CHIAKI_CONTROLLER_BUTTON_PYRAMID;
	if(!strcmp(n, "options")) return CHIAKI_CONTROLLER_BUTTON_OPTIONS;
	if(!strcmp(n, "ps")) return CHIAKI_CONTROLLER_BUTTON_PS;
	return 0;
}

static void tap(Stream *s, uint32_t button)
{
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	st.buttons = button;
	chiaki_session_set_controller_state(&s->session, &st);
	usleep(120000);
	chiaki_controller_state_set_idle(&st);
	chiaki_session_set_controller_state(&s->session, &st);
}

// Reads one key from a raw terminal without blocking. Returns a button, 'q' as -1, or 0.
static int64_t poll_key(void)
{
	fd_set fds; FD_ZERO(&fds); FD_SET(0, &fds);
	struct timeval tv = {0, 0};
	if(select(1, &fds, NULL, NULL, &tv) <= 0) return 0;
	unsigned char c[3] = {0};
	ssize_t n = read(0, c, 3);
	if(n <= 0) return 0;
	if(n == 3 && c[0] == 27 && c[1] == '[')
	{
		switch(c[2]) {
			case 'A': return CHIAKI_CONTROLLER_BUTTON_DPAD_UP;
			case 'B': return CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN;
			case 'C': return CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT;
			case 'D': return CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT;
		}
		return 0;
	}
	switch(c[0]) {
		case 'x': return CHIAKI_CONTROLLER_BUTTON_CROSS;
		case 'o': return CHIAKI_CONTROLLER_BUTTON_MOON;
		case 's': return CHIAKI_CONTROLLER_BUTTON_BOX;
		case 't': return CHIAKI_CONTROLLER_BUTTON_PYRAMID;
		case 'p': return CHIAKI_CONTROLLER_BUTTON_PS;
		case '\r': case '\n': return CHIAKI_CONTROLLER_BUTTON_OPTIONS;
		case 'q': case 3: return -1;
	}
	return 0;
}

static int cmd_stream(ChiakiLog *log, const char *host, int argc, char **argv)
{
	Cred cred;
	if(!cred_load(host, &cred)) { fprintf(stderr, "No saved pairing for %s. Run register first.\n", host); return 2; }

	double seconds = 0; bool view = false; const char *record_dir = NULL; char *taps = NULL;
	static Stream s; memset(&s, 0, sizeof(s));
	for(int i = 0; i < argc; i++)
	{
		if(!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
		else if(!strcmp(argv[i], "--view")) view = true;
		else if(!strcmp(argv[i], "--record") && i + 1 < argc) record_dir = argv[++i];
		else if(!strcmp(argv[i], "--tap") && i + 1 < argc) taps = strdup(argv[++i]);
		else if(!strcmp(argv[i], "--login-pin") && i + 1 < argc) s.login_pin = argv[++i];
		else { fprintf(stderr, "Unknown option %s\n", argv[i]); return 2; }
	}

	ChiakiConnectInfo ci = {0};
	ci.ps5 = true;
	ci.host = host;
	memcpy(ci.regist_key, cred.regist_key, sizeof(ci.regist_key));
	memcpy(ci.morning, cred.rp_key, sizeof(ci.morning));
	memcpy(ci.psn_account_id, cred.account_id, sizeof(ci.psn_account_id));
	chiaki_connect_video_profile_preset(&ci.video_profile, CHIAKI_VIDEO_RESOLUTION_PRESET_720p, CHIAKI_VIDEO_FPS_PRESET_60);
	ci.video_profile.codec = CHIAKI_CODEC_H264;
	ci.video_profile_auto_downgrade = true;
	ci.audio_video_disabled = CHIAKI_NONE_DISABLED;
	ci.packet_loss_max = 0.05;
	ci.enable_idr_on_fec_failure = true;

	if(record_dir)
	{
		char path[1024];
		snprintf(path, sizeof(path), "%s/session.h264", record_dir); s.video_out = fopen(path, "wb");
		snprintf(path, sizeof(path), "%s/session.s16le.pcm", record_dir); s.audio_out = fopen(path, "wb");
		if(!s.video_out || !s.audio_out) { fprintf(stderr, "Cannot write into %s\n", record_dir); return 2; }
		printf("Recording this session into %s (asked for with --record)\n", record_dir);
	}
	if(view)
	{
		signal(SIGPIPE, SIG_IGN);
		s.video_view = popen("ffplay -loglevel error -fflags nobuffer -flags low_delay -framedrop -f h264 -window_title 'PS5 live (prototype)' -i - 2>/dev/null", "w");
		s.audio_view = popen("ffplay -loglevel error -nodisp -fflags nobuffer -f s16le -ar 48000 -ch_layout stereo -i - 2>/dev/null", "w");
	}

	ChiakiErrorCode err = chiaki_session_init(&s.session, &ci, log);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "Session init failed: %s\n", chiaki_error_string(err)); return 1; }
	ChiakiOpusDecoder opus;
	chiaki_opus_decoder_init(&opus, log);
	chiaki_opus_decoder_set_cb(&opus, audio_settings_cb, audio_frame_cb, &s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&opus, &sink);
	chiaki_session_set_audio_sink(&s.session, &sink);
	chiaki_session_set_video_sample_cb(&s.session, video_cb, &s);
	chiaki_session_set_event_cb(&s.session, event_cb, &s);

	err = chiaki_session_start(&s.session);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "Session start failed: %s\n", chiaki_error_string(err)); return 1; }

	struct termios old_tio; bool raw = false;
	if(isatty(0))
	{
		tcgetattr(0, &old_tio);
		struct termios tio = old_tio; tio.c_lflag &= ~(ICANON | ECHO); tio.c_cc[VMIN] = 0; tio.c_cc[VTIME] = 0;
		tcsetattr(0, TCSANOW, &tio); raw = true;
		printf("Keys: arrows = D-pad, x = Cross, o = Circle, s = Square, t = Triangle, p = PS, Enter = Options, q = quit\n");
	}

	double start = now_s(), connected_at = 0, last_report = start, next_tap = 0;
	char *tap_cursor = taps ? strtok(taps, ",") : NULL;
	unsigned long taps_sent = 0;
	while(!g_stop && !s.quit)
	{
		usleep(20000);
		double t = now_s();
		if(s.connected && !connected_at) { connected_at = t; next_tap = t + 3; }
		if(!s.connected && t - start > 30) { printf("EVENT no connection after 30 s\n"); break; }
		if(seconds > 0 && connected_at && t - connected_at >= seconds) break;

		if(connected_at && tap_cursor && t >= next_tap)
		{
			uint32_t b = button_from_name(tap_cursor);
			if(b) { tap(&s, b); taps_sent++; printf("INPUT sent tap: %s\n", tap_cursor); }
			else printf("INPUT unknown button name: %s\n", tap_cursor);
			tap_cursor = strtok(NULL, ",");
			next_tap = t + 1.5;
		}
		if(raw && connected_at)
		{
			int64_t k = poll_key();
			if(k < 0) break;
			if(k > 0) { tap(&s, (uint32_t)k); taps_sent++; }
		}
		if(connected_at && t - last_report >= 1.0)
		{
			double dt = t - last_report;
			printf("STATS video %.0f fps, %.2f Mbps, %lu frames lost | audio %.0f packets/s\n",
				s.video_frames / dt, s.video_bytes * 8 / dt / 1e6, (unsigned long)s.frames_lost, s.audio_frames / dt);
			fflush(stdout);
			s.video_frames = 0; s.video_bytes = 0; s.audio_frames = 0;
			last_report = t;
		}
	}
	if(raw) tcsetattr(0, TCSANOW, &old_tio);

	chiaki_session_stop(&s.session);
	chiaki_session_join(&s.session);
	chiaki_session_fini(&s.session);
	chiaki_opus_decoder_fini(&opus);
	if(s.video_out) fclose(s.video_out);
	if(s.audio_out) fclose(s.audio_out);
	if(s.video_view) pclose(s.video_view);
	if(s.audio_view) pclose(s.audio_view);

	printf("RESULT stream: connected=%s, video frames received=%lu, audio packets decoded=%lu, input taps sent=%lu, rumble events=%lu\n",
		connected_at ? "yes" : "no", s.total_video_frames, s.total_audio_frames, taps_sent, (unsigned long)s.rumble_events);
	return connected_at && s.total_video_frames > 0 ? 0 : 1;
}

// ---- main --------------------------------------------------------------------------------

int main(int argc, char **argv)
{
	if(argc < 3)
	{
		fprintf(stderr,
			"usage:\n"
			"  %s register <host> <account-id-base64> [pin]\n"
			"  %s wake <host>\n"
			"  %s stream <host> [--seconds N] [--view] [--record DIR] [--tap right,left,cross] [--login-pin NNNN]\n"
			"  %s forget <host>\n", argv[0], argv[0], argv[0], argv[0]);
		return 2;
	}
	signal(SIGINT, on_sigint);
	ChiakiErrorCode err = chiaki_lib_init();
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "Library init failed: %s\n", chiaki_error_string(err)); return 1; }
	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, log_cb, NULL);

	const char *cmd = argv[1], *host = argv[2];
	if(!strcmp(cmd, "register") && argc >= 4)
	{
		// The library prints the decrypted pairing reply (which contains the keys) at info level.
		chiaki_log_set_level(&log, CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR);
		return cmd_register(&log, host, argv[3], argc >= 5 ? argv[4] : NULL);
	}
	if(0) return cmd_register(&log, host, argv[3], argc >= 5 ? argv[4] : NULL);
	if(!strcmp(cmd, "wake")) return cmd_wake(&log, host);
	if(!strcmp(cmd, "stream")) return cmd_stream(&log, host, argc - 3, argv + 3);
	if(!strcmp(cmd, "forget")) { cred_delete(host); printf("RESULT forget: pairing for %s removed from the Keychain\n", host); return 0; }
	fprintf(stderr, "Unknown command or missing arguments.\n");
	return 2;
}
