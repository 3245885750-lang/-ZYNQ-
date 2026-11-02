#include "radar_stream_ring.h"
#include <string.h>

void radar_ring_push(RadarStreamRing *r, const int16_t *samples,
                     uint32_t before, uint32_t after)
{
    uint32_t slot = (uint32_t)(r->total_frames % STREAM_RING_FRAMES);
    memcpy(r->ring[slot], samples, RADAR_V2_AUDIO_FRAME_BYTES);
    r->frame_ids[slot] = r->total_frames;
    r->dropped_before[slot] = before;
    r->dropped_after[slot] = after;
    ++r->total_frames;
}

void radar_ring_request(RadarStreamRing *r, uint32_t frames, uint64_t end_frame)
{
    r->snapshot_copied = 0;
    r->snapshot_error = 0;
    r->snapshot_frames = frames;
    r->snapshot_start = r->snapshot_end = 0;
    r->snapshot_dropped_before = r->snapshot_dropped_after = 0;
    if (!end_frame) end_frame = r->total_frames;
    if (!frames || frames > STREAM_SNAPSHOT_FRAMES || end_frame < frames ||
        end_frame > r->total_frames ||
        r->total_frames - (end_frame - frames) > STREAM_RING_FRAMES) {
        r->snapshot_state = STREAM_SNAPSHOT_ERROR;
        r->snapshot_error = STREAM_ERR_HISTORY;
        return;
    }
    r->snapshot_end = end_frame;
    r->snapshot_start = r->snapshot_end - frames;
    r->snapshot_dropped_before = r->dropped_before[r->snapshot_start % STREAM_RING_FRAMES];
    r->snapshot_dropped_after = r->dropped_after[(r->snapshot_end - 1) % STREAM_RING_FRAMES];
    r->snapshot_state = STREAM_SNAPSHOT_COPYING;
}

void radar_ring_copy_step(RadarStreamRing *r, uint32_t budget)
{
    if (r->snapshot_state != STREAM_SNAPSHOT_COPYING) return;
    while (budget-- && r->snapshot_copied < r->snapshot_frames) {
        uint64_t frame = r->snapshot_start + r->snapshot_copied;
        uint32_t slot = (uint32_t)(frame % STREAM_RING_FRAMES);
        /* A delayed consumer must fail rather than export overwritten history. */
        if (r->frame_ids[slot] != frame) {
            r->snapshot_state = STREAM_SNAPSHOT_ERROR;
            r->snapshot_error = STREAM_ERR_OVERWRITTEN;
            return;
        }
        if (r->dropped_before[slot] != r->snapshot_dropped_before ||
            r->dropped_after[slot] != r->snapshot_dropped_before ||
            r->dropped_after[slot] == UINT32_MAX) {
            r->snapshot_state = STREAM_SNAPSHOT_ERROR;
            r->snapshot_error = STREAM_ERR_LOSS;
            return;
        }
        memcpy(r->snapshot[r->snapshot_copied], r->ring[slot],
               RADAR_V2_AUDIO_FRAME_BYTES);
        ++r->snapshot_copied;
    }
    if (r->snapshot_copied == r->snapshot_frames)
        r->snapshot_state = STREAM_SNAPSHOT_READY;
}
