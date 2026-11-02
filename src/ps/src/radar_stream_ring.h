#ifndef RADAR_STREAM_RING_H
#define RADAR_STREAM_RING_H

#include <stdint.h>
#include "radar_audio_v2.h"

#define STREAM_RING_FRAMES 8192U
#define STREAM_SNAPSHOT_FRAMES 4096U
#define STREAM_COPY_BUDGET 16U
#define STREAM_SNAPSHOT_IDLE 0U
#define STREAM_SNAPSHOT_COPYING 1U
#define STREAM_SNAPSHOT_READY 2U
#define STREAM_SNAPSHOT_ERROR 3U
#define STREAM_ERR_HISTORY 1U
#define STREAM_ERR_OVERWRITTEN 2U
#define STREAM_ERR_LOSS 3U

typedef struct {
    int16_t ring[STREAM_RING_FRAMES][RADAR_V2_AUDIO_FRAME_SAMPLES];
    int16_t snapshot[STREAM_SNAPSHOT_FRAMES][RADAR_V2_AUDIO_FRAME_SAMPLES];
    uint64_t frame_ids[STREAM_RING_FRAMES];
    uint32_t dropped_before[STREAM_RING_FRAMES];
    uint32_t dropped_after[STREAM_RING_FRAMES];
    uint64_t total_frames;
    uint64_t snapshot_start;
    uint64_t snapshot_end;
    uint32_t snapshot_state;
    uint32_t snapshot_error;
    uint32_t snapshot_copied;
    uint32_t snapshot_frames;
    uint32_t snapshot_dropped_before;
    uint32_t snapshot_dropped_after;
} RadarStreamRing;

void radar_ring_push(RadarStreamRing *ring, const int16_t *samples,
                     uint32_t dropped_before, uint32_t dropped_after);
void radar_ring_request(RadarStreamRing *ring, uint32_t frames, uint64_t end_frame);
void radar_ring_copy_step(RadarStreamRing *ring, uint32_t budget);

#endif
