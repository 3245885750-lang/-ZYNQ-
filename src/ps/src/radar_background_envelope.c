#include "radar_background_envelope.h"
#include "noise_floor.inc"
#include <math.h>
#include <string.h>

void radar_background_reset(RadarBackgroundEnvelope *s)
{
    if (s) memset(s, 0, sizeof(*s));
}

int radar_background_frame(RadarBackgroundEnvelope *s, const float logmel[40])
{
    float delta[40], sorted[40], total = 0;
    if (!s || !logmel) return -1;
    if (s->invalid) return -1;
    for (unsigned i = 0; i < 40; ++i) {
        if (!isfinite(logmel[i])) { s->invalid = 1; return -1; }
        delta[i] = sorted[i] = logmel[i] - noise_floor_db[i];
    }
    for (unsigned i = 1; i < 40; ++i) {
        float v = sorted[i];
        unsigned j = i;
        while (j && sorted[j-1] > v) { sorted[j] = sorted[j-1]; --j; }
        sorted[j] = v;
    }
    float gain = (sorted[19] + sorted[20]) * .5f;
    if (gain < 0) gain = 0;
    if (gain > 6) gain = 6;
    for (unsigned i = 0; i < 40; ++i) {
        float excess = delta[i] - gain;
        if (excess > 0) total += excess;
    }
    float strength = total / 40.0f;
    ++s->frames;
    if (strength >= 3) ++s->active_frames;
    if (gain >= 6) ++s->capped_frames;
    if (strength > s->peak_excess_db) s->peak_excess_db = strength;
    s->total_excess_db += strength;
    s->total_gain_db += gain;
    return 0;
}

int radar_background_finish(const RadarBackgroundEnvelope *s)
{
    if (!s || !s->frames || s->invalid) return -1;
    if (s->active_frames * 20U >= s->frames || s->peak_excess_db >= 12) return 2;
    if (s->active_frames * 50U >= s->frames || s->peak_excess_db >= 6) return 1;
    return 0;
}
