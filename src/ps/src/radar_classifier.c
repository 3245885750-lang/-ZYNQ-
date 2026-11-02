#include "radar_classifier.h"
#include <math.h>
#include <string.h>
#include "radar_classifier_data.inc"

#define NFFT 512U
#define NBINS 257U
#define NFRAMES ((RADAR_CLASS_WINDOW - 400U) / 160U + 1U)
#define NMEL 40U
#define NMFCC 20U
/* One bounded operation per step; the caller services multiple steps within
 * a measured wall-clock budget while DMA acquisition retains priority. */
#define FFT_BATCH 1U
#define STATS_BATCH 8U
#if RADAR_CLASS_WINDOW < 560U || RADAR_CLASS_HOP < 160U || RADAR_CLASS_HOP % 160U || NFRAMES > 256U
#error Invalid window/hop
#endif
#ifndef RADAR_USE_FFT_CACHE
#define RADAR_USE_FFT_CACHE 1
#endif
#define CACHE_FRAMES (NFRAMES <= 64U ? 64U : 256U)
/* Mel energy after window-dependent DC removal is a quadratic in the mean.
 * Cache its raw energy/cross terms, not just FFT bins; overlap hits then skip
 * both FFT and Mel matrix work. Double terms limit cancellation/roundoff. */
static double cached_mel[CACHE_FRAMES][NMEL], cached_cross[CACHE_FRAMES][NMEL];
static double cached_power[CACHE_FRAMES], cached_power_cross[CACHE_FRAMES];
static double cached_centroid[CACHE_FRAMES], cached_centroid_cross[CACHE_FRAMES];
static uint64_t cached_start[CACHE_FRAMES];
static unsigned char cached_valid[CACHE_FRAMES];
static float hann_re[NBINS], hann_im[NBINS];
static double hann_mel[NMEL], hann_power, hann_centroid;
static uint32_t cache_hits, cache_misses;
int radar_classifier_busy(void);
void radar_classifier_cache_counts(uint32_t *hits, uint32_t *misses) {
    if (hits) *hits = cache_hits;
    if (misses) *misses = cache_misses;
}

static float audio_ring[RADAR_CLASS_WINDOW];
static float window_audio[RADAR_CLASS_WINDOW];
static float raw_logmel[NFRAMES][NMEL];
static float frame_zcr[NFRAMES], frame_centroid[NFRAMES];
static float fft_real[NFFT], fft_imag[NFFT], power_bins[NBINS];
static float raw_history[64];
static uint64_t raw_count, resample_time;
static uint64_t output_count, window_end;
static uint32_t ring_position, available, since_window;
static uint32_t stage, frame_index, sequence, gaps, missed;
static float window_mean, maximum_log, window_rms;
static double sum[64], sumsq[64];
static double delta_sum[NMFCC];
static float last_mfcc[NMFCC];
static float output_features[144], output_scores[RADAR_CLASS_COUNT];
static RadarBackgroundEnvelope background_work, background_completed;
static int background_state = -1;
int radar_classifier_background(RadarBackgroundEnvelope *snapshot)
{
    if (snapshot) *snapshot = background_completed;
    return background_state;
}


static float nonnegative_std(double total, double square, unsigned count)
{
    double mean = total / count;
    double variance = square / count - mean * mean;
    return (float)sqrt(variance > 0 ? variance : 0);
}

static void fft512(void)
{
    unsigned j = 0;
    for (unsigned i = 1; i < NFFT; ++i) {
        unsigned bit = NFFT >> 1;
        while (j & bit) { j ^= bit; bit >>= 1; }
        j ^= bit;
        if (i < j) {
            float r = fft_real[i], im = fft_imag[i];
            fft_real[i] = fft_real[j]; fft_imag[i] = fft_imag[j];
            fft_real[j] = r; fft_imag[j] = im;
        }
    }
    for (unsigned length = 2; length <= NFFT; length <<= 1) {
        unsigned half = length >> 1, stride = NFFT / length;
        for (unsigned base = 0; base < NFFT; base += length) {
            for (unsigned k = 0; k < half; ++k) {
                unsigned a = base + k, b = a + half, t = k * stride;
                float r = fft_real[b] * class_fft_cos[t] - fft_imag[b] * class_fft_sin[t];
                float im = fft_real[b] * class_fft_sin[t] + fft_imag[b] * class_fft_cos[t];
                fft_real[b] = fft_real[a] - r; fft_imag[b] = fft_imag[a] - im;
                fft_real[a] += r; fft_imag[a] += im;
            }
        }
    }
}

static void analyse_frame(unsigned frame)
{
    const float *samples = window_audio + frame * 160U;
    unsigned crossings = 0;
    /* Avoid catastrophic cancellation when a large DC offset dominates a very
     * small signal. In this exceptional case use the original centered FFT. */
    int direct = fabsf(window_mean) > window_rms;
    double power_sum = 0, centroid_sum = 0;
    if (direct) {
        for (unsigned i = 0; i < 400U; ++i) {
            fft_real[i] = (samples[i] - window_mean) * class_hann[i];
            fft_imag[i] = 0;
        }
        for (unsigned i = 400U; i < NFFT; ++i) { fft_real[i] = 0; fft_imag[i] = 0; }
        fft512(); ++cache_misses;
        for (unsigned i=0;i<NBINS;++i) {
            float p=fft_real[i]*fft_real[i]+fft_imag[i]*fft_imag[i];
            power_bins[i]=p;power_sum+=p;centroid_sum+=p*(i/256.0);
        }
    } else {
    uint64_t sample_start = window_end - RADAR_CLASS_WINDOW + frame * 160U;
    unsigned slot = (unsigned)((sample_start / 160U) % CACHE_FRAMES);
    int hit = RADAR_USE_FFT_CACHE && cached_valid[slot] && cached_start[slot] == sample_start;
    if (!hit) {
        /* Cache the FFT BEFORE subtracting the per-window mean. Centering is
         * window-dependent, so caching a centered FFT would be incorrect. */
        for (unsigned i = 0; i < 400U; ++i) {
            fft_real[i] = samples[i] * class_hann[i]; fft_imag[i] = 0;
        }
        for (unsigned i = 400U; i < NFFT; ++i) { fft_real[i] = 0; fft_imag[i] = 0; }
        fft512();
        double cross[NBINS];
        cached_power[slot]=cached_power_cross[slot]=0;
        cached_centroid[slot]=cached_centroid_cross[slot]=0;
        for (unsigned i=0;i<NBINS;++i) {
            double re=fft_real[i], im=fft_imag[i];
            power_bins[i]=(float)(re*re+im*im);
            cross[i]=re*hann_re[i]+im*hann_im[i];
            cached_power[slot]+=power_bins[i];cached_power_cross[slot]+=cross[i];
            cached_centroid[slot]+=power_bins[i]*(i/256.0);
            cached_centroid_cross[slot]+=cross[i]*(i/256.0);
        }
        unsigned wi=0;
        for (unsigned b=0;b<NMEL;++b) {
            double e=0,c=0;
            for (unsigned k=0;k<class_mel_count[b];++k) {
                unsigned bin=class_mel_start[b]+k;float w=class_mel_weight[wi++];
                e+=power_bins[bin]*w;c+=cross[bin]*w;
            }
            cached_mel[slot][b]=e;cached_cross[slot][b]=c;
        }
        cached_start[slot] = sample_start; cached_valid[slot] = 1U;
        ++cache_misses;
    } else ++cache_hits;
    double mean=window_mean;
    power_sum=cached_power[slot]-2*mean*cached_power_cross[slot]+mean*mean*hann_power;
    centroid_sum=cached_centroid[slot]-2*mean*cached_centroid_cross[slot]+mean*mean*hann_centroid;
    for (unsigned b=0;b<NMEL;++b) {
        double energy=cached_mel[slot][b]-2*mean*cached_cross[slot][b]+mean*mean*hann_mel[b];
        float log_energy=10.0f*log10f((float)(energy>1e-12?energy:1e-12));
        raw_logmel[frame][b]=log_energy;
        if(log_energy>maximum_log)maximum_log=log_energy;
    }
    }
    for (unsigned i = 1; i < 400U; ++i)
        if (signbit(samples[i]-window_mean) != signbit(samples[i-1U]-window_mean)) ++crossings;
    frame_zcr[frame] = crossings / 399.0f;
    frame_centroid[frame] = (float)(centroid_sum / (power_sum > 1e-12 ? power_sum : 1e-12));
    if (!direct) return;
    unsigned weight_index = 0;
    for (unsigned band = 0; band < NMEL; ++band) {
        float energy = 0;
        for (unsigned k = 0; k < class_mel_count[band]; ++k)
            energy += power_bins[class_mel_start[band] + k] * class_mel_weight[weight_index++];
        float log_energy = 10.0f * log10f(energy > 1e-12f ? energy : 1e-12f);
        raw_logmel[frame][band] = log_energy;
        if (log_energy > maximum_log) maximum_log = log_energy;
    }
}

static void add_stat(unsigned index, float value)
{
    sum[index] += value;
    sumsq[index] += (double)value * value;
}

static void stats_frame(unsigned frame)
{
    /* Absolute spectral levels, before relative model normalization.
     * Spread over the existing stats stages to retain DMA priority. */
    radar_background_frame(&background_work, raw_logmel[frame]);
    float normalized[NMEL];
    for (unsigned band = 0; band < NMEL; ++band) {
        float value = raw_logmel[frame][band] - maximum_log;
        normalized[band] = value > -80.0f ? value : -80.0f;
        add_stat(band, normalized[band]);
    }
    for (unsigned coefficient = 0; coefficient < NMFCC; ++coefficient) {
        float value = 0;
        for (unsigned band = 0; band < NMEL; ++band)
            value += class_dct[coefficient * NMEL + band] * normalized[band];
        add_stat(40U + coefficient, value);
        if (frame) delta_sum[coefficient] += fabsf(value - last_mfcc[coefficient]);
        last_mfcc[coefficient] = value;
    }
    add_stat(60U, frame_zcr[frame]);
    add_stat(61U, frame_centroid[frame]);
}

static void network(const float *features, float *scores)
{
    float normalized[144], first[64], second[32];
    for (unsigned i = 0; i < 144U; ++i) {
        float v = (features[i] - class_mean[i]) / class_std[i];
        normalized[i] = v < -8 ? -8 : v > 8 ? 8 : v;
    }
    for (unsigned j = 0; j < 64U; ++j) {
        float v = class_b1[j];
        for (unsigned i = 0; i < 144U; ++i) v += normalized[i] * class_w1[i * 64U + j];
        first[j] = v > 0 ? v : 0;
    }
    for (unsigned j = 0; j < 32U; ++j) {
        float v = class_b2[j];
        for (unsigned i = 0; i < 64U; ++i) v += first[i] * class_w2[i * 32U + j];
        second[j] = v > 0 ? v : 0;
    }
    float maximum = -1e30f, total = 0;
    for (unsigned j = 0; j < RADAR_CLASS_COUNT; ++j) {
        float v = class_b3[j];
        for (unsigned i = 0; i < 32U; ++i) v += second[i] * class_w3[i * RADAR_CLASS_COUNT + j];
        scores[j] = v;
        if (v > maximum) maximum = v;
    }
    for (unsigned i = 0; i < RADAR_CLASS_COUNT; ++i) { scores[i] = expf(scores[i] - maximum); total += scores[i]; }
    for (unsigned i = 0; i < RADAR_CLASS_COUNT; ++i) scores[i] /= total;
}

static void begin_window(void)
{
    radar_background_reset(&background_work);
    double total = 0, square = 0;
    for (unsigned i = 0; i < RADAR_CLASS_WINDOW; ++i) {
        float v = window_audio[i];
        total += v; square += (double)v * v;
    }
    window_mean = (float)(total / RADAR_CLASS_WINDOW);
    window_rms = nonnegative_std(total, square, RADAR_CLASS_WINDOW);
    maximum_log = -1e30f;
    memset(sum, 0, sizeof sum); memset(sumsq, 0, sizeof sumsq);
    memset(delta_sum, 0, sizeof delta_sum);
    frame_index = 0;
    stage = 1;
}

static void finish_window(void)
{
    for (unsigned i = 0; i < 40U; ++i) {
        output_features[i] = (float)(sum[i] / NFRAMES);
        output_features[40U + i] = nonnegative_std(sum[i], sumsq[i], NFRAMES);
    }
    for (unsigned i = 0; i < 20U; ++i) {
        output_features[80U + i] = (float)(sum[40U + i] / NFRAMES);
        output_features[100U + i] = nonnegative_std(sum[40U + i], sumsq[40U + i], NFRAMES);
        output_features[120U + i] = (float)(delta_sum[i] / (NFRAMES - 1U));
    }
    output_features[140] = (float)(sum[60] / NFRAMES);
    output_features[141] = nonnegative_std(sum[60], sumsq[60], NFRAMES);
    output_features[142] = (float)(sum[61] / NFRAMES);
    output_features[143] = nonnegative_std(sum[61], sumsq[61], NFRAMES);
    network(output_features, output_scores);
    background_completed = background_work;
    background_state = radar_background_finish(&background_completed);
}

int radar_classifier_busy(void) { return stage != 0U; }

void radar_classifier_init(void)
{
    memset(cached_valid, 0, sizeof cached_valid);
    cache_hits = cache_misses = 0;
    for (unsigned i = 0; i < NFFT; ++i) {
        fft_real[i] = i < 400U ? class_hann[i] : 0; fft_imag[i] = 0;
    }
    fft512();
    memcpy(hann_re, fft_real, sizeof hann_re);
    memcpy(hann_im, fft_imag, sizeof hann_im);
    hann_power=hann_centroid=0;
    double hp[NBINS];
    for(unsigned i=0;i<NBINS;++i) {
        double re=hann_re[i],im=hann_im[i];hp[i]=re*re+im*im;
        hann_power+=hp[i];hann_centroid+=hp[i]*(i/256.0);
    }
    unsigned wi=0;
    for(unsigned b=0;b<NMEL;++b) {
        hann_mel[b]=0;
        for(unsigned k=0;k<class_mel_count[b];++k)
            hann_mel[b]+=hp[class_mel_start[b]+k]*class_mel_weight[wi++];
    }
    radar_background_reset(&background_work);
    radar_background_reset(&background_completed);
    background_state = -1;
    memset(raw_history, 0, sizeof raw_history);
    raw_count = 0; resample_time = 31250U;
    output_count = 0; ring_position = available = since_window = 0;
    stage = sequence = gaps = missed = 0;
}

void radar_classifier_discontinuity(void)
{
    memset(cached_valid, 0, sizeof cached_valid);
    radar_background_reset(&background_work);
    radar_background_reset(&background_completed);
    background_state = -1;
    ++gaps;
    memset(raw_history, 0, sizeof raw_history);
    raw_count = 0; resample_time = 31250U;
    available = since_window = ring_position = stage = 0;
}

static void push_16k(float sample)
{
    audio_ring[ring_position] = sample;
    ring_position = (ring_position + 1U) % RADAR_CLASS_WINDOW;
    ++output_count;
    if (available < RADAR_CLASS_WINDOW) {
        ++available;
        if (available == RADAR_CLASS_WINDOW) since_window = RADAR_CLASS_HOP;
    } else ++since_window;
    if (available == RADAR_CLASS_WINDOW && since_window >= RADAR_CLASS_HOP) {
        since_window = 0;
        if (stage) { ++missed; return; }
        unsigned tail = RADAR_CLASS_WINDOW - ring_position;
        memcpy(window_audio, audio_ring + ring_position, tail * sizeof(float));
        memcpy(window_audio + tail, audio_ring, ring_position * sizeof(float));
        window_end = output_count;
        begin_window();
    }
}

void radar_classifier_push_pcm(const int16_t *pcm, unsigned count)
{
    for (unsigned i = 0; i < count; ++i) {
        raw_history[raw_count & 63U] = pcm[i] / 32768.0f;
        while (resample_time / 1024U <= raw_count) {
            uint64_t center = resample_time / 1024U;
            unsigned phase = (unsigned)(resample_time % 1024U);
            float value = 0;
            for (unsigned k = 0; k < 62U && k <= center; ++k)
                value += raw_history[(center - k) & 63U] * class_resample[phase * 62U + k];
            push_16k(value);
            resample_time += 3125U;
        }
        ++raw_count;
    }
}

int radar_classifier_step(RadarClassification *result)
{
    if (stage == 1U) {
        for (unsigned n = 0; n < FFT_BATCH && frame_index < NFRAMES; ++n)
            analyse_frame(frame_index++);
        if (frame_index == NFRAMES) {stage = 2U; frame_index = 0;}
    } else if (stage == 2U) {
        for (unsigned n = 0; n < STATS_BATCH && frame_index < NFRAMES; ++n)
            stats_frame(frame_index++);
        if (frame_index == NFRAMES) stage = 3U;
    } else if (stage == 3U) {
        finish_window();
        stage = 0;
        unsigned best = 0;
        for (unsigned i = 1; i < RADAR_CLASS_COUNT; ++i) if (output_scores[i] > output_scores[best]) best = i;
        result->sequence = ++sequence;
        result->end_sample = window_end;
        result->label = best;
        memcpy(result->scores, output_scores, sizeof output_scores);
        result->rms = window_rms;
        result->valid = window_rms > 1e-9f && radar_class_accept_float(output_scores, best);
        result->gap_count = gaps;
        result->missed_windows = missed;
        return 1;
    }
    return 0;
}

const char *radar_classifier_label(unsigned index)
{
    return index < RADAR_CLASS_COUNT ? class_names[index] : "unknown";
}

int radar_classifier_window(const float *audio, float *features, float *scores)
{
    /* Standalone reference calls have no streaming sample identity. */
    memset(cached_valid, 0, sizeof cached_valid);
    window_end = RADAR_CLASS_WINDOW;
    memcpy(window_audio, audio, sizeof window_audio);
    begin_window();
    for (unsigned i = 0; i < NFRAMES; ++i) analyse_frame(i);
    for (unsigned i = 0; i < NFRAMES; ++i) stats_frame(i);
    finish_window(); stage = 0;
    memcpy(features, output_features, sizeof output_features);
    memcpy(scores, output_scores, sizeof output_scores);
    return 0;
}

#ifdef RADAR_NATIVE_TEST
void radar_test_push_16k(const float *samples, unsigned n) {
    for (unsigned i=0;i<n;++i) push_16k(samples[i]);
}
void radar_test_features(float *out) { memcpy(out, output_features, sizeof output_features); }
unsigned radar_test_missed(void) { return missed; }
#endif
