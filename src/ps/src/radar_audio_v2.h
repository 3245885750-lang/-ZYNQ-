#ifndef RADAR_AUDIO_V2_H
#define RADAR_AUDIO_V2_H

#include <stdint.h>

/* Generated integration contract. Do not use this with the old FFT bitstream. */
#define RADAR_V2_BASE             UINT32_C(0x43c00000)
#define RADAR_V2_RANGE            UINT32_C(0x1000)
#define RADAR_V2_DMA_BASE         UINT32_C(0x40400000)
#define RADAR_V2_CTRL             UINT32_C(0x00)
#define RADAR_V2_STATUS           UINT32_C(0x04)
#define RADAR_V2_MVDR_DOA         UINT32_C(0x08)
#define RADAR_V2_SMIN             UINT32_C(0x0c)
#define RADAR_V2_SHIFT            UINT32_C(0x10)
#define RADAR_V2_SNAPSHOT_COUNT   UINT32_C(0x14)
#define RADAR_V2_BINS01           UINT32_C(0x18)
#define RADAR_V2_VERSION          UINT32_C(0x1c)
#define RADAR_V2_DAS_DOA          UINT32_C(0x20)
#define RADAR_V2_DAS_SIGNAL       UINT32_C(0x24)
#define RADAR_V2_BINS23           UINT32_C(0x28)
#define RADAR_V2_BINS45           UINT32_C(0x2c)
#define RADAR_V2_BINS67           UINT32_C(0x30)
#define RADAR_V2_POWER            UINT32_C(0x34)
#define RADAR_V2_DAS_SEQ          UINT32_C(0x38)
#define RADAR_V2_MVDR_SEQ         UINT32_C(0x3c)
#define RADAR_V2_AUDIO_DROPPED    UINT32_C(0x40)
#define RADAR_V2_INTERFACE        UINT32_C(0x44)
#define RADAR_V2_AUDIO_SENT       UINT32_C(0x48)
#define RADAR_V2_INTERFACE_MAGIC  UINT32_C(0x41554432)
#define RADAR_V2_VERSION_MAGIC    UINT32_C(0x4d564452)

/* Must match PL PWR_TH used by mvdr_print; raw PWR register scale, not dB. */
#define RADAR_V2_MVDR_POWER_THRESHOLD UINT32_C(0x00000040)

/* One PL-scale activity gate for both DOA and sound classification output. */
static inline int radar_signal_active(uint32_t power)
{
    return power > RADAR_V2_MVDR_POWER_THRESHOLD;
}

#define RADAR_V2_AUDIO_FRAME_SAMPLES 1024u
#define RADAR_V2_AUDIO_FRAME_BYTES   2048u
#define RADAR_V2_AUDIO_RATE_NUM      50000000u
#define RADAR_V2_AUDIO_RATE_DEN      1024u
#define RADAR_V2_AUDIO_FIFO_SAMPLES  4096u

/* DOA registers contain sign-extended int32_t degrees in [-180, 180].
 * For coherent reads: seq1 -> angle (+ DAS signal) -> seq2, accept if equal.
 * A nonzero unchanged sequence means no new committed result; do not use
 * sticky DONE as a freshness flag. Retry a bounded number of times.
 * Sequence and AUDIO_SENT wrap modulo 2^32; AUDIO_DROPPED saturates.
 * Registers reset with PL reset. CTRL soft reset affects the MVDR core only.
 * DMA frame samples are signed little-endian int16_t. No WAV/JSON header.
 * AUDIO_SENT counts accepted samples at the PL-to-external-FIFO boundary,
 * not the number written to DDR; it may lead the DMA by FIFO occupancy.
 * Dropped > 0 invalidates continuity, but does not identify the lost position.
 */

#endif
