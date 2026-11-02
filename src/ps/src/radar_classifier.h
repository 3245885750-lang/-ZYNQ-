#ifndef RADAR_CLASSIFIER_H
#define RADAR_CLASSIFIER_H
#include <stdint.h>
#include "radar_class_policy.h"
#include "radar_background_envelope.h"

#define RADAR_CLASS_COUNT 9U
/* Keep validated 2s context/weights; update results every 100ms. */
#ifndef RADAR_CLASS_WINDOW
#define RADAR_CLASS_WINDOW 32000U
#endif
#ifndef RADAR_CLASS_HOP
#define RADAR_CLASS_HOP 1600U
#endif
int radar_classifier_busy(void);
void radar_classifier_cache_counts(uint32_t *hits, uint32_t *misses);

typedef struct {
    uint32_t sequence;
    uint64_t end_sample;
    uint32_t label;
    float scores[RADAR_CLASS_COUNT];
    float rms;
    uint32_t valid;
    uint32_t gap_count;
    uint32_t missed_windows;
} RadarClassification;

/* Snapshot of the last COMPLETED window; -1 during warmup/after a gap. */
int radar_classifier_background(RadarBackgroundEnvelope *snapshot);
void radar_classifier_init(void);
void radar_classifier_discontinuity(void);
void radar_classifier_push_pcm(const int16_t *pcm, unsigned count);
/* Cooperatively advances a bounded stage; acquisition retains priority. */
int radar_classifier_step(RadarClassification *result);
const char *radar_classifier_label(unsigned index);

/* Portable reference entry point for matching the trained Python frontend. */
int radar_classifier_window(const float *audio, float *features, float *scores);

#endif
