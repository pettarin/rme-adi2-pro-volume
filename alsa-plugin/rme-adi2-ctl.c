/*
 * rme-adi2-ctl - ALSA control bridge for RME ADI-2 Pro/DAC
 *
 * Creates a user control on the sound card that MPD can use as hardware mixer.
 * Monitors control changes and sends MIDI SysEx to the ADI-2 device.
 *
 * This enables bit-perfect audio with hardware volume control.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <getopt.h>
#include <poll.h>
#include <errno.h>
#include <alsa/asoundlib.h>

#define CONTROL_NAME "ADI2"
#define DEFAULT_CARD "ADI-2"
#define DEFAULT_DEVICE_ID 0x72

/* Volume range: 0-600 representing -60.0 to 0.0 dB (0.1 dB steps) */
#define VOL_MIN 0
#define VOL_MAX 600
#define VOL_DEFAULT 300  /* -30 dB */

/* RME device IDs */
#define RME_DEVICE_DAC    0x71
#define RME_DEVICE_PRO    0x72
#define RME_DEVICE_PRO_SE 0x73

/* RME output parameters */
#define RME_PARAM_LINE   0x1B
#define RME_PARAM_PHONES 0x4B
#define RME_PARAM_MUTE   0x61

/* NOTE: We intentionally do NOT use TLV.
 * Without TLV, MPD treats the control as linear percentage (0-100%),
 * and our daemon maps that linearly to the configured dB range.
 * This gives intuitive control where 50% = exactly halfway between min and max dB.
 */

/* Global state */
static volatile sig_atomic_t running = 1;
static int verbose = 0;

/* Configuration */
static struct {
    char card_name[64];
    int card_num;
    char midi_port[32];
    int device_id;
    int output_param;
    double min_db;
    double max_db;
} config = {
    .card_name = DEFAULT_CARD,
    .card_num = -1,
    .midi_port = "",
    .device_id = DEFAULT_DEVICE_ID,
    .output_param = RME_PARAM_LINE,
    .min_db = -70.0,
    .max_db = -15.0,
};

static void signal_handler(int sig)
{
    (void)sig;
    running = 0;
}

static void log_info(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(ap);
}

static void log_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "Error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(ap);
}

static void log_verbose(const char *fmt, ...)
{
    if (!verbose)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(ap);
}

/* Find card number by name substring */
static int find_card_by_name(const char *name)
{
    int card = -1;
    char *card_name;

    while (snd_card_next(&card) >= 0 && card >= 0) {
        if (snd_card_get_name(card, &card_name) < 0)
            continue;
        if (strstr(card_name, name) != NULL) {
            log_verbose("Found card %d: %s", card, card_name);
            free(card_name);
            return card;
        }
        free(card_name);
    }
    return -1;
}

/* Find MIDI port for the card */
static int find_midi_port(int card, char *port, size_t port_len)
{
    /* Try common MIDI port naming: hw:card,0,0 */
    snprintf(port, port_len, "hw:%d,0,0", card);

    /* Verify the port exists by trying to open it */
    snd_rawmidi_t *midi = NULL;
    int err = snd_rawmidi_open(NULL, &midi, port, SND_RAWMIDI_NONBLOCK);
    if (err < 0) {
        /* Try without subdevice */
        snprintf(port, port_len, "hw:%d,0", card);
        err = snd_rawmidi_open(NULL, &midi, port, SND_RAWMIDI_NONBLOCK);
    }
    if (err >= 0) {
        snd_rawmidi_close(midi);
        return 0;
    }
    return -1;
}

/* Convert control value (0-600) to dB
 * Linear mapping: 0 = min_db, 600 = max_db
 * This gives intuitive volume control where 50% is halfway between min and max.
 */
static double value_to_db(int value)
{
    /* Linear interpolation from min_db to max_db */
    return config.min_db + (config.max_db - config.min_db) * value / VOL_MAX;
}

/* Convert dB to RME SysEx bytes */
static void db_to_sysex_bytes(double dB, unsigned char *x, unsigned char *y)
{
    int raw = (int)(dB * 10) + 4096;

    /* Clamp to valid RME range: -114dB to +6dB */
    if (raw < 940)
        raw = 940;   /* -114 dB */
    if (raw > 4156)
        raw = 4156;  /* +6 dB */

    *x = (raw >> 7) & 0x1F;
    *y = raw & 0x7F;
}

/* Send volume to ADI-2 via MIDI SysEx */
static int send_volume(snd_rawmidi_t *midi, int value)
{
    double dB = value_to_db(value);
    unsigned char x, y;
    db_to_sysex_bytes(dB, &x, &y);

    unsigned char sysex[] = {
        0xF0,                   /* SysEx start */
        0x00, 0x20, 0x0D,       /* RME manufacturer ID */
        config.device_id,       /* Device ID */
        0x02,                   /* Command: set value */
        config.output_param,    /* Parameter: output volume */
        x, y,                   /* Volume bytes */
        0xF7                    /* SysEx end */
    };

    log_verbose("Volume %d -> %.1f dB -> SysEx: %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X",
                value, dB,
                sysex[0], sysex[1], sysex[2], sysex[3], sysex[4],
                sysex[5], sysex[6], sysex[7], sysex[8], sysex[9]);

    ssize_t written = snd_rawmidi_write(midi, sysex, sizeof(sysex));
    if (written < 0) {
        log_error("MIDI write failed: %s", snd_strerror(written));
        return -1;
    }

    log_info("Volume: %.1f dB", dB);
    return 0;
}

/* Create user control on the card */
static int create_control(snd_ctl_t *ctl, snd_ctl_elem_id_t *id)
{
    snd_ctl_elem_info_t *info;
    int err;

    snd_ctl_elem_info_alloca(&info);

    /* Set up element ID */
    snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
    snd_ctl_elem_id_set_name(id, CONTROL_NAME);

    /* Check if control already exists */
    snd_ctl_elem_info_set_id(info, id);
    err = snd_ctl_elem_info(ctl, info);
    if (err == 0) {
        /* Control exists - try to remove it first */
        log_verbose("Removing existing control");
        snd_ctl_elem_remove(ctl, id);
    }

    /* Create new integer control */
    snd_ctl_elem_info_set_id(info, id);
    err = snd_ctl_add_integer_elem_set(ctl, info, 1, 1, VOL_MIN, VOL_MAX, 1);
    if (err < 0) {
        log_error("Failed to create control: %s", snd_strerror(err));
        return err;
    }

    /* Get the assigned element number */
    snd_ctl_elem_info_get_id(info, id);
    log_verbose("Created control '%s' numid=%d", CONTROL_NAME,
                snd_ctl_elem_id_get_numid(id));

    /* NOTE: We intentionally do NOT set TLV (dB scale info).
     * Without TLV, MPD/moOde treats the control as linear percentage,
     * and our daemon maps linearly to the configured dB range.
     * This gives intuitive control where 50% = halfway between min and max dB.
     */

    /* Set initial value */
    snd_ctl_elem_value_t *value;
    snd_ctl_elem_value_alloca(&value);
    snd_ctl_elem_value_set_id(value, id);
    snd_ctl_elem_value_set_integer(value, 0, VOL_DEFAULT);
    err = snd_ctl_elem_write(ctl, value);
    if (err < 0) {
        log_error("Failed to set initial value: %s", snd_strerror(err));
    }

    /* Unlock the control so other processes can write to it */
    err = snd_ctl_elem_unlock(ctl, id);
    if (err < 0) {
        log_verbose("Unlock failed (non-fatal): %s", snd_strerror(err));
    }

    return 0;
}

/* Read current control value */
static int read_control_value(snd_ctl_t *ctl, snd_ctl_elem_id_t *id)
{
    snd_ctl_elem_value_t *value;
    snd_ctl_elem_value_alloca(&value);
    snd_ctl_elem_value_set_id(value, id);

    int err = snd_ctl_elem_read(ctl, value);
    if (err < 0) {
        log_error("Failed to read control: %s", snd_strerror(err));
        return -1;
    }

    return snd_ctl_elem_value_get_integer(value, 0);
}

/* Main monitoring loop */
static int monitor_loop(snd_ctl_t *ctl, snd_ctl_elem_id_t *id, snd_rawmidi_t *midi)
{
    int err;
    int last_value = -1;

    /* Subscribe to control events */
    err = snd_ctl_subscribe_events(ctl, 1);
    if (err < 0) {
        log_error("Cannot subscribe to events: %s", snd_strerror(err));
        return err;
    }

    /* Get poll descriptors */
    int count = snd_ctl_poll_descriptors_count(ctl);
    if (count <= 0) {
        log_error("Invalid poll descriptor count: %d", count);
        return -1;
    }
    struct pollfd pfd[count];
    snd_ctl_poll_descriptors(ctl, pfd, count);

    /* Read and send initial value */
    int value = read_control_value(ctl, id);
    if (value >= 0) {
        send_volume(midi, value);
        last_value = value;
    }

    log_info("Monitoring control '%s' for changes...", CONTROL_NAME);

    while (running) {
        err = poll(pfd, count, -1);  /* Block until event or signal */
        if (err < 0) {
            if (errno == EINTR)
                continue;
            log_error("Poll error: %s", strerror(errno));
            break;
        }

        /* Check poll result */
        unsigned short revents;
        snd_ctl_poll_descriptors_revents(ctl, pfd, count, &revents);
        if (!(revents & POLLIN))
            continue;

        /* Read events */
        snd_ctl_event_t *event;
        snd_ctl_event_alloca(&event);

        while (snd_ctl_read(ctl, event) > 0) {
            if (snd_ctl_event_get_type(event) != SND_CTL_EVENT_ELEM)
                continue;

            /* Check if it's our control */
            unsigned int event_numid = snd_ctl_event_elem_get_numid(event);
            unsigned int our_numid = snd_ctl_elem_id_get_numid(id);

            if (event_numid != our_numid)
                continue;

            /* Read new value */
            value = read_control_value(ctl, id);
            if (value >= 0 && value != last_value) {
                send_volume(midi, value);
                last_value = value;
            }
            break;  /* Process one event per poll, then check running flag */
        }
    }

    return 0;
}

static void print_usage(const char *prog)
{
    printf("Usage: %s [options]\n\n", prog);
    printf("Creates an ALSA mixer control for RME ADI-2 hardware volume.\n\n");
    printf("Options:\n");
    printf("  -c, --card NAME    Sound card name to search for (default: %s)\n", DEFAULT_CARD);
    printf("  -C, --card-num N   Use card number N directly\n");
    printf("  -m, --midi PORT    MIDI port (default: auto-detect)\n");
    printf("  -d, --device ID    RME device ID: 71=DAC, 72=Pro, 73=Pro SE (default: 72)\n");
    printf("  -o, --output TYPE  Output: line or phones (default: line)\n");
    printf("      --min-db DB    Minimum dB (0%% volume) (default: -60.0)\n");
    printf("      --max-db DB    Maximum dB (100%% volume) (default: -15.0)\n");
    printf("  -v, --verbose      Verbose output\n");
    printf("  -h, --help         Show this help\n");
    printf("\nExample:\n");
    printf("  %s --card ADI-2 --device 72 --max-db -20\n", prog);
}

static int parse_args(int argc, char *argv[])
{
    static struct option long_opts[] = {
        {"card",     required_argument, 0, 'c'},
        {"card-num", required_argument, 0, 'C'},
        {"midi",     required_argument, 0, 'm'},
        {"device",   required_argument, 0, 'd'},
        {"output",   required_argument, 0, 'o'},
        {"min-db",   required_argument, 0, 'n'},
        {"max-db",   required_argument, 0, 'x'},
        {"verbose",  no_argument,       0, 'v'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "c:C:m:d:o:n:x:vh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'c':
            strncpy(config.card_name, optarg, sizeof(config.card_name) - 1);
            break;
        case 'C':
            config.card_num = atoi(optarg);
            break;
        case 'm':
            strncpy(config.midi_port, optarg, sizeof(config.midi_port) - 1);
            break;
        case 'd':
            config.device_id = strtol(optarg, NULL, 0);
            if (config.device_id != RME_DEVICE_DAC &&
                config.device_id != RME_DEVICE_PRO &&
                config.device_id != RME_DEVICE_PRO_SE) {
                log_error("Invalid device ID: 0x%02X", config.device_id);
                return -1;
            }
            break;
        case 'o':
            if (strcmp(optarg, "line") == 0) {
                config.output_param = RME_PARAM_LINE;
            } else if (strcmp(optarg, "phones") == 0) {
                config.output_param = RME_PARAM_PHONES;
            } else {
                log_error("Invalid output: %s (use 'line' or 'phones')", optarg);
                return -1;
            }
            break;
        case 'n':
            config.min_db = atof(optarg);
            break;
        case 'x':
            config.max_db = atof(optarg);
            break;
        case 'v':
            verbose = 1;
            break;
        case 'h':
            print_usage(argv[0]);
            exit(0);
        default:
            return -1;
        }
    }

    return 0;
}

int main(int argc, char *argv[])
{
    snd_ctl_t *ctl = NULL;
    snd_rawmidi_t *midi = NULL;
    snd_ctl_elem_id_t *id;
    char card_hw[32];
    int err;
    int ret = 1;

    snd_ctl_elem_id_alloca(&id);

    if (parse_args(argc, argv) < 0) {
        print_usage(argv[0]);
        return 1;
    }

    /* Set up signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Find card */
    if (config.card_num < 0) {
        config.card_num = find_card_by_name(config.card_name);
        if (config.card_num < 0) {
            log_error("Card '%s' not found", config.card_name);
            goto cleanup;
        }
    }
    log_info("Using card %d", config.card_num);

    /* Find MIDI port */
    if (config.midi_port[0] == '\0') {
        if (find_midi_port(config.card_num, config.midi_port,
                           sizeof(config.midi_port)) < 0) {
            log_error("No MIDI port found for card %d", config.card_num);
            goto cleanup;
        }
    }
    log_info("Using MIDI port %s", config.midi_port);

    /* Open control device */
    snprintf(card_hw, sizeof(card_hw), "hw:%d", config.card_num);
    err = snd_ctl_open(&ctl, card_hw, 0);
    if (err < 0) {
        log_error("Cannot open control %s: %s", card_hw, snd_strerror(err));
        goto cleanup;
    }

    /* Open MIDI output */
    err = snd_rawmidi_open(NULL, &midi, config.midi_port, 0);
    if (err < 0) {
        log_error("Cannot open MIDI %s: %s", config.midi_port, snd_strerror(err));
        goto cleanup;
    }

    /* Create control */
    err = create_control(ctl, id);
    if (err < 0)
        goto cleanup;

    log_info("RME ADI-2 control bridge started");
    log_info("Device ID: 0x%02X, Output: %s",
             config.device_id,
             config.output_param == RME_PARAM_LINE ? "line" : "phones");

    /* Run monitoring loop */
    monitor_loop(ctl, id, midi);

    log_info("Shutting down...");
    ret = 0;

cleanup:
    /* Remove control before closing */
    if (ctl && snd_ctl_elem_id_get_numid(id) > 0) {
        log_verbose("Removing control");
        snd_ctl_elem_remove(ctl, id);
    }

    if (midi)
        snd_rawmidi_close(midi);
    if (ctl)
        snd_ctl_close(ctl);

    return ret;
}
