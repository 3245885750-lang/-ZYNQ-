#include "xparameters.h"
#include "xaxidma.h"
#include "xgpiops.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "sleep.h"
#include "radar_stream_ring.h"
#include "radar_network.h"
#ifdef RADAR_ENABLE_CLASSIFIER
#include "radar_classifier.h"
#endif

#define STREAM_MAGIC UINT32_C(0x53545231)
#define RX_REG (RADAR_V2_DMA_BASE + XAXIDMA_RX_OFFSET)
#define LED_PIN 7U
#define STATE_BOOT 1U
#define STATE_RUNNING 2U
#define STATE_STOPPED 3U
#define STATE_ERROR 4U

/* Live mailbox: host writes ONLY request_id[34], stop_request[45],
 * request_frames[49], and optional end_frame[50:51] (before request_id).
 * Firmware publishes all other fields under the seqlock at [55].
 * Snapshot stays immutable until the next request. DMA never targets it.
 */
volatile uint32_t g_stream_header[64] __attribute__((aligned(64)));
RadarStreamRing g_stream_ring __attribute__((aligned(64)));
static int16_t dma_frames[2][RADAR_V2_AUDIO_FRAME_SAMPLES] __attribute__((aligned(64)));
static XAxiDma dma;
static XGpioPs gpio;
static int gpio_ready;
static int dma_ready;
static uint32_t state = STATE_BOOT;
static uint32_t led_level;
static uint32_t error_code;
static uint32_t request_active;
static uint32_t request_ack;
static uint32_t dropped_initial;
static uint32_t sent_initial;
static uint32_t dropped_last;
static uint32_t peak_last;
static uint32_t average_last;
static uint32_t last_dma_status;
static uint32_t last_dma_bytes;
static uint32_t max_work_ticks;
static uint32_t last_das_angle;
static uint32_t last_mvdr_angle;
static XTime capture_start;
static uint32_t pl_read(uint32_t offset);
#ifdef RADAR_ENABLE_CLASSIFIER
volatile uint32_t g_classifier_header[64] __attribute__((aligned(64)));
static RadarClassification classification;
static uint32_t class_max_step_ticks, class_max_push_ticks;
static XTime class_window_started;
static uint32_t class_last_elapsed_ticks, class_max_elapsed_ticks;

static void publish_classification(void)
{
    XTime now;
    XTime_GetTime(&now);
    ++g_classifier_header[55];
    __asm__ volatile("dsb sy" ::: "memory");
    g_classifier_header[0] = UINT32_C(0x434c5331);
    g_classifier_header[1] = 2U;
    g_classifier_header[2] = state;
    g_classifier_header[3] = classification.sequence;
    g_classifier_header[4] = classification.valid ? classification.label : RADAR_CLASS_COUNT;
    g_classifier_header[5] = (uint32_t)(classification.scores[classification.label] * 1000000.0f);
    g_classifier_header[6] = (uint32_t)classification.end_sample;
    g_classifier_header[7] = (uint32_t)(classification.end_sample >> 32);
    g_classifier_header[8] = RADAR_CLASS_WINDOW;
    g_classifier_header[9] = RADAR_CLASS_HOP;
    g_classifier_header[10] = (uint32_t)(classification.rms * 32768000.0f);
    g_classifier_header[11] = classification.valid;
    g_classifier_header[12] = classification.gap_count;
    g_classifier_header[13] = classification.missed_windows;
    g_classifier_header[14] = error_code;
    g_classifier_header[15] = COUNTS_PER_SECOND;
    g_classifier_header[16] = (uint32_t)now;
    g_classifier_header[17] = (uint32_t)(now >> 32);
    g_classifier_header[18] = dropped_last;
    g_classifier_header[19] = class_max_step_ticks;
    g_classifier_header[20] = class_max_push_ticks;
    for (unsigned i = 0; i < RADAR_CLASS_COUNT; ++i)
        g_classifier_header[i < 8U ? 21U + i : 48U] = (uint32_t)(classification.scores[i] * 1000000.0f);
    g_classifier_header[29] = pl_read(RADAR_V2_DAS_DOA);
    g_classifier_header[30] = pl_read(RADAR_V2_MVDR_DOA);
    g_classifier_header[31] = pl_read(RADAR_V2_DAS_SEQ);
    g_classifier_header[32] = pl_read(RADAR_V2_MVDR_SEQ);
    g_classifier_header[33] = max_work_ticks;
    RadarBackgroundEnvelope bg;
    int bg_state = radar_classifier_background(&bg);
    g_classifier_header[34] = UINT32_C(0x42473031); /* BG01 */
    g_classifier_header[35] = 1U;
    g_classifier_header[36] = (uint32_t)(bg_state + 1);
    g_classifier_header[37] = bg.frames ? bg.active_frames * 1000000U / bg.frames : 0U;
    g_classifier_header[38] = (uint32_t)(bg.peak_excess_db * 1000.0f);
    g_classifier_header[39] = bg.frames ? (uint32_t)(bg.total_excess_db / bg.frames * 1000.0f) : 0U;
    g_classifier_header[40] = bg.frames ? bg.capped_frames * 1000000U / bg.frames : 0U;
    g_classifier_header[41] = 20261028U;
    g_classifier_header[42] = UINT32_C(0x434c5031); /* CLP1 policy */
    g_classifier_header[43] = RADAR_ENABLED_CLASS_MASK;
    g_classifier_header[44] = classification.sequence && !classification.valid;
    g_classifier_header[45] = 2U;
    g_classifier_header[46] = classification.label; /* preserved raw top class */
    g_classifier_header[47] = classification.sequence && classification.rms > 1e-9f;
    g_classifier_header[49] = RADAR_CLASS_COUNT;
    g_classifier_header[50] = RADAR_REJECT_CONFIDENCE_PPM;
    g_classifier_header[51] = RADAR_REJECT_MARGIN_PPM;
    uint32_t hits, misses;
    radar_classifier_cache_counts(&hits, &misses);
    g_classifier_header[56] = UINT32_C(0x4c415431); /* LAT1 diagnostics */
    g_classifier_header[57] = hits;
    g_classifier_header[58] = misses;
    g_classifier_header[59] = class_last_elapsed_ticks;
    g_classifier_header[60] = class_max_elapsed_ticks;
    g_classifier_header[61] = 12U; /* soft budget per DMA frame, ms */
    g_classifier_header[62] = (RADAR_CLASS_WINDOW - 400U) / 160U + 1U;
    g_classifier_header[63] = 10U; /* UART prints every tenth result */

    __asm__ volatile("dsb sy" ::: "memory");
    ++g_classifier_header[55];
}
#endif

static uint32_t pl_read(uint32_t offset)
{
    return Xil_In32(RADAR_V2_BASE + offset);
}

static void barrier(void) { __asm__ volatile("dsb sy" ::: "memory"); }

static void set_led(uint32_t level)
{
    if (gpio_ready) XGpioPs_WritePin(&gpio, LED_PIN, level);
    led_level = gpio_ready ? level : 0U;
    barrier();
}

static int init_led(void)
{
#ifdef SDT
    XGpioPs_Config *cfg = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_BASEADDR);
#else
    XGpioPs_Config *cfg = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_DEVICE_ID);
#endif
    if (!cfg || XGpioPs_CfgInitialize(&gpio, cfg, cfg->BaseAddr) != XST_SUCCESS)
        return 3;
    XGpioPs_WritePin(&gpio, LED_PIN, 0U);
    XGpioPs_SetDirectionPin(&gpio, LED_PIN, 1U);
    XGpioPs_SetOutputEnablePin(&gpio, LED_PIN, 1U);
    gpio_ready = 1;
    set_led(0);
    return 0;
}

static void publish(void)
{
    XTime now;
    XTime_GetTime(&now);
    ++g_stream_header[55];
    barrier();
    g_stream_header[0] = STREAM_MAGIC;
    g_stream_header[1] = 1U;
    g_stream_header[2] = state;
    g_stream_header[3] = error_code;
    g_stream_header[4] = RADAR_V2_AUDIO_FRAME_BYTES;
    g_stream_header[5] = RADAR_V2_AUDIO_FRAME_SAMPLES;
    g_stream_header[6] = RADAR_V2_AUDIO_RATE_NUM;
    g_stream_header[7] = RADAR_V2_AUDIO_RATE_DEN;
    g_stream_header[8] = STREAM_RING_FRAMES;
    g_stream_header[9] = (uint32_t)(UINTPTR)g_stream_ring.ring;
    g_stream_header[10] = (uint32_t)g_stream_ring.total_frames;
    g_stream_header[11] = (uint32_t)(g_stream_ring.total_frames >> 32);
    g_stream_header[12] = g_stream_ring.total_frames < STREAM_RING_FRAMES
        ? (uint32_t)g_stream_ring.total_frames : STREAM_RING_FRAMES;
    g_stream_header[13] = (uint32_t)(g_stream_ring.total_frames % STREAM_RING_FRAMES);
    g_stream_header[14] = dropped_initial;
    g_stream_header[15] = dropped_last;
    g_stream_header[16] = sent_initial;
    g_stream_header[17] = pl_read(RADAR_V2_AUDIO_SENT);
    g_stream_header[18] = last_dma_status;
    g_stream_header[19] = last_dma_bytes;
    g_stream_header[20] = (uint32_t)g_stream_ring.total_frames;
    g_stream_header[21] = LED_PIN;
    g_stream_header[22] = led_level;
    g_stream_header[23] = (uint32_t)capture_start;
    g_stream_header[24] = (uint32_t)(capture_start >> 32);
    g_stream_header[25] = (uint32_t)now;
    g_stream_header[26] = (uint32_t)(now >> 32);
    g_stream_header[27] = (uint32_t)COUNTS_PER_SECOND;
    g_stream_header[28] = pl_read(RADAR_V2_INTERFACE);
    g_stream_header[29] = pl_read(RADAR_V2_VERSION);
    g_stream_header[30] = peak_last;
    g_stream_header[31] = average_last;
    g_stream_header[32] = (uint32_t)(UINTPTR)g_stream_ring.snapshot;
    g_stream_header[33] = STREAM_SNAPSHOT_FRAMES;
    g_stream_header[35] = request_ack;
    g_stream_header[36] = g_stream_ring.snapshot_state;
    g_stream_header[37] = g_stream_ring.snapshot_state == STREAM_SNAPSHOT_READY
        ? g_stream_ring.snapshot_frames : 0U;
    g_stream_header[38] = (uint32_t)g_stream_ring.snapshot_start;
    g_stream_header[39] = (uint32_t)(g_stream_ring.snapshot_start >> 32);
    g_stream_header[40] = (uint32_t)g_stream_ring.snapshot_end;
    g_stream_header[41] = (uint32_t)(g_stream_ring.snapshot_end >> 32);
    g_stream_header[42] = g_stream_ring.snapshot_copied;
    g_stream_header[43] = g_stream_ring.snapshot_dropped_before;
    g_stream_header[44] = g_stream_ring.snapshot_dropped_after;
    g_stream_header[46] = state == STATE_STOPPED ? 1U : 0U;
    g_stream_header[47] = g_stream_ring.snapshot_error;
    g_stream_header[48] = request_active;
    g_stream_header[56] = last_das_angle;
    g_stream_header[57] = last_mvdr_angle;
    g_stream_header[58] = g_stream_header[34];
    g_stream_header[59] = max_work_ticks;
    barrier();
    ++g_stream_header[55];
    barrier();
}

static int start_frame(unsigned slot)
{
    XAxiDma_IntrAckIrq(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    return XAxiDma_SimpleTransfer(&dma, (UINTPTR)dma_frames[slot],
        RADAR_V2_AUDIO_FRAME_BYTES, XAXIDMA_DEVICE_TO_DMA) == XST_SUCCESS ? 0 : 10;
}

static int wait_frame(int allow_partial)
{
    XTime begin, now;
    XTime_GetTime(&begin);
    for (;;) {
        last_dma_status = XAxiDma_ReadReg(RX_REG, XAXIDMA_SR_OFFSET);
        if (last_dma_status & (XAXIDMA_ERR_ALL_MASK | XAXIDMA_IRQ_ERROR_MASK))
            return 11;
        if (last_dma_status & XAXIDMA_IRQ_IOC_MASK) {
            last_dma_bytes = XAxiDma_ReadReg(RX_REG, XAXIDMA_BUFFLEN_OFFSET);
            barrier();
            if (!last_dma_bytes || last_dma_bytes > RADAR_V2_AUDIO_FRAME_BYTES ||
                (last_dma_bytes & 1U) ||
                (!allow_partial && last_dma_bytes != RADAR_V2_AUDIO_FRAME_BYTES))
                return 12;
            return 0;
        }
        XTime_GetTime(&now);
        if (now - begin > (XTime)COUNTS_PER_SECOND * 3U) return 13;
        radar_network_service();
    }
}

static void process_frame(const int16_t *samples)
{
    uint32_t sum = 0, peak = 0;
    uint32_t after = pl_read(RADAR_V2_AUDIO_DROPPED);
    radar_ring_push(&g_stream_ring, samples, dropped_last, after);
#ifdef RADAR_ENABLE_CLASSIFIER
    if (after != dropped_last || after == UINT32_MAX) {
        radar_classifier_discontinuity();
        classification.valid = 0;
        ++classification.gap_count;
    }
#endif
    dropped_last = after;
    for (unsigned i = 0; i < RADAR_V2_AUDIO_FRAME_SAMPLES; ++i) {
        int32_t sample = samples[i];
        uint32_t a = (uint32_t)(sample < 0 ? -sample : sample);
        sum += a;
        if (a > peak) peak = a;
    }
    peak_last = peak;
    average_last = sum / RADAR_V2_AUDIO_FRAME_SAMPLES;
    /* These angles are telemetry at snapshot request time, not audio-aligned labels. */
    if (g_stream_ring.snapshot_state != STREAM_SNAPSHOT_COPYING &&
        g_stream_header[34] != request_ack) {
        request_active = g_stream_header[34];
        last_das_angle = pl_read(RADAR_V2_DAS_DOA);
        last_mvdr_angle = pl_read(RADAR_V2_MVDR_DOA);
        uint64_t end_frame = g_stream_header[50] | ((uint64_t)g_stream_header[51] << 32);
        radar_ring_request(&g_stream_ring, g_stream_header[49], end_frame);
    }
    radar_ring_copy_step(&g_stream_ring, STREAM_COPY_BUDGET);
    if (g_stream_ring.snapshot_state == STREAM_SNAPSHOT_READY ||
        g_stream_ring.snapshot_state == STREAM_SNAPSHOT_ERROR)
        request_ack = request_active;
#ifdef RADAR_ENABLE_CLASSIFIER
    XTime begin, pushed, finished;
    XTime_GetTime(&begin);
    int was_busy = radar_classifier_busy();
    radar_classifier_push_pcm(samples, RADAR_V2_AUDIO_FRAME_SAMPLES);
    XTime_GetTime(&pushed);
    if (!was_busy && radar_classifier_busy()) class_window_started = begin;
    /* 12 ms SOFT budget: checked between bounded operations, so allow one
     * operation of overshoot. Actual worst step + total DMA work need board
     * measurement; CPU cache/DMA coherency configuration is unchanged. */
    int ready = 0;
    do {
        if (!radar_classifier_busy()) break;
        if (radar_classifier_step(&classification)) { ready = 1; break; }
        XTime_GetTime(&finished);
    } while (finished - pushed < (XTime)COUNTS_PER_SECOND * 12U / 1000U);
    XTime_GetTime(&finished);
    if (ready) {
        class_last_elapsed_ticks = (uint32_t)(finished - class_window_started);
        if (class_last_elapsed_ticks > class_max_elapsed_ticks)
            class_max_elapsed_ticks = class_last_elapsed_ticks;
    }
    if (pushed - begin > class_max_push_ticks) class_max_push_ticks = (uint32_t)(pushed - begin);
    if (finished - pushed > class_max_step_ticks) class_max_step_ticks = (uint32_t)(finished - pushed);
    if (ready && classification.sequence % 10U == 0U) {
        xil_printf("CLASSIFY seq=%u type=%s score_ppm=%u rms_mpcm=%u gaps=%u missed=%u\r\n",
            classification.sequence, radar_signal_active(pl_read(RADAR_V2_POWER)) ? (classification.valid ? radar_classifier_label(classification.label) : "uncertain") : "background",
            (unsigned)(classification.scores[classification.label] * 1000000.0f),
            (unsigned)(classification.rms * 32768000.0f), classification.gap_count,
            classification.missed_windows);
    }
    publish_classification();
    radar_network_publish(&classification);
#endif
}

int main(void)
{
    Xil_ICacheEnable();
    /* Cortex-A9 Xil_ICacheEnable also enables the shared L2 cache.
     * Disable data/L2 caches LAST: HP DMA and JTAG are not coherent with L2.
     * Otherwise reused ping-pong buffers return old audio indefinitely.
     * L1 instruction caching remains enabled for continuous processing.
     */
    Xil_DCacheDisable();
    barrier();
#ifdef RADAR_ENABLE_CLASSIFIER
    radar_classifier_init();
#endif
    usleep(1U);
    error_code = (uint32_t)init_led();
    if (error_code) goto finish;
    if (pl_read(RADAR_V2_INTERFACE) != RADAR_V2_INTERFACE_MAGIC ||
        pl_read(RADAR_V2_VERSION) != RADAR_V2_VERSION_MAGIC) {
        error_code = 1U;
        goto finish;
    }
#ifdef SDT
    XAxiDma_Config *cfg = XAxiDma_LookupConfig(RADAR_V2_DMA_BASE);
#else
    XAxiDma_Config *cfg = XAxiDma_LookupConfigBaseAddr(RADAR_V2_DMA_BASE);
#endif
    if (!cfg || XAxiDma_CfgInitialize(&dma, cfg) != XST_SUCCESS ||
        XAxiDma_HasSg(&dma)) {
        error_code = 2U;
        goto finish;
    }
    dma_ready = 1;
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    if (radar_network_init() != 0)
        xil_printf("NET_UNAVAILABLE audio continues; check network mailbox\r\n");
    /* Align to TLAST and remove startup backlog before continuity accounting. */
    for (unsigned i = 0; i < 16U; ++i) {
        error_code = (uint32_t)start_frame(0);
        if (!error_code) error_code = (uint32_t)wait_frame(i == 0U);
        if (error_code) goto finish;
    }
    dropped_initial = dropped_last = pl_read(RADAR_V2_AUDIO_DROPPED);
    sent_initial = pl_read(RADAR_V2_AUDIO_SENT);
    XTime_GetTime(&capture_start);
    state = STATE_RUNNING;
    error_code = (uint32_t)start_frame(0);
    if (error_code) goto finish;
    set_led(1U);
    publish();
#ifdef RADAR_ENABLE_CLASSIFIER
    publish_classification();
#endif
    xil_printf("\r\nCONTINUOUS_LISTENING PS_LED0=MIO7 ON\r\n");
    unsigned current = 0;
    for (;;) {
        XTime work_start, work_end;
        error_code = (uint32_t)wait_frame(0);
        if (error_code) break;
        XTime_GetTime(&work_start);
        int stop_requested = g_stream_header[45] != 0U;
        /* Arm the other DMA buffer before copying or servicing a snapshot. */
        if (!stop_requested) {
            error_code = (uint32_t)start_frame(current ^ 1U);
            if (error_code) break;
        }
        process_frame(dma_frames[current]);
        radar_network_service();
        XTime_GetTime(&work_end);
        if (work_end - work_start > max_work_ticks)
            max_work_ticks = (uint32_t)(work_end - work_start);
        if (stop_requested) {state = STATE_STOPPED; break;}
        publish();
        current ^= 1U;
    }
finish:
    if (error_code) state = STATE_ERROR;
    radar_network_stop(error_code);
    set_led(0U);
    if (dma_ready) XAxiDma_Reset(&dma);
    publish();
#ifdef RADAR_ENABLE_CLASSIFIER
    publish_classification();
#endif
    xil_printf("CONTINUOUS_STOP state=%u error=%u\r\n", state, error_code);
    for (;;) { __asm__ volatile("nop"); }
}
