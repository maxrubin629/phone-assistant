#ifndef CALL_AUDIO_DSP_H
#define CALL_AUDIO_DSP_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Exactly one producer and one consumer may access each ring. Control threads
 * may change its generation concurrently. Creation/destruction are worker-only;
 * destroy requires both producer and consumer to have stopped. All other ring
 * functions are bounded, allocation-free and use verified lock-free atomics.
 * Generation values must not be reused during a ring's lifetime. */
typedef struct CABRing CABRing;

typedef struct CABRingCounters {
    uint64_t accepted_frames;
    uint64_t delivered_frames;
    uint64_t overflow_frames;
    uint64_t stale_frames;
    uint64_t underrun_frames;
    uint64_t rejected_generation_frames;
} CABRingCounters;

/* Capacity is an exact frame count, 1..2^24. Returns NULL on allocation failure,
 * invalid capacity, or a platform without lock-free 64-bit atomics. */
CABRing *cab_ring_create(size_t capacity, uint64_t initial_generation);
void cab_ring_destroy(CABRing *ring);
size_t cab_ring_capacity(const CABRing *ring);
/* Approximate instantaneous backlog, including obsolete-generation slots not
 * yet drained. Independent index reads are clamped to the ring's capacity. */
size_t cab_ring_queued_frames(const CABRing *ring);
uint64_t cab_ring_generation(const CABRing *ring);
/* Does not reset indices or counters. Old queued samples are discarded by the
 * consumer, so neither endpoint ever writes the other endpoint's index. */
void cab_ring_set_generation(CABRing *ring, uint64_t generation);

/* Returns frames queued; overflow drops the incoming tail, never unread data.
 * Samples are sanitized to finite [-1,1] values before publication. */
size_t cab_ring_write(CABRing *ring, const float *input, size_t frames,
                      uint64_t expected_generation);
/* Always fills output[0..<frames], padding missing/stale samples with silence.
 * Returns non-padding frames delivered. If generation changes during the call,
 * the entire output is silenced and zero is returned. */
size_t cab_ring_read(CABRing *ring, float *output, size_t frames,
                     uint64_t expected_generation);
CABRingCounters cab_ring_counters(const CABRing *ring);

/* These six flags match the route model. Model ingress is gated by the worker
 * using the caller/mic-to-agent flags. cab_mix_monitor handles local listening. */
enum {
    CAB_ROUTE_MIC_TO_CALLER = 1u << 0,
    CAB_ROUTE_AGENT_TO_CALLER = 1u << 1,
    CAB_ROUTE_CALLER_TO_AGENT = 1u << 2,
    CAB_ROUTE_MIC_TO_AGENT = 1u << 3,
    CAB_ROUTE_CALLER_TO_USER = 1u << 4,
    CAB_ROUTE_AGENT_TO_USER = 1u << 5,
    CAB_ROUTE_ALL = 63u
};

typedef struct CABControls CABControls;
typedef struct CABControlsSnapshot {
    uint32_t routes;
    float mic_gain;
    float agent_gain;
    float monitor_gain;
    float monitor_agent_gain;
    uint32_t limiter_enabled;
    float limiter_ceiling;
    float limiter_release_ms;
} CABControlsSnapshot;

/* Controls have no locks or callback allocations. Gains are independently
 * atomic (a snapshot is not a transaction); update routes last when enabling.
 * Non-finite/negative gains become zero, and positive gains are limited to 4. */
CABControls *cab_controls_create(void);
void cab_controls_destroy(CABControls *controls);
void cab_controls_set_routes(CABControls *controls, uint32_t routes);
uint32_t cab_controls_routes(const CABControls *controls);
/* Created enabled, with revision 1 and phone send muted. Muting preserves the
 * configured routes but masks both microphone and agent routes to the caller.
 * Disabled controls expose no effective routes. */
void cab_controls_set_send_muted(CABControls *controls, bool muted);
void cab_controls_set_enabled(CABControls *controls, bool enabled);
/* Disable and advance revision in one atomic operation. Call directly from an
 * emergency-stop handler before enqueuing device teardown on a worker. */
void cab_controls_cancel(CABControls *controls);
uint64_t cab_controls_revision(const CABControls *controls);
/* Async startup must use this conditional enable to avoid resurrecting routes
 * after cancellation races its final revision check. False means superseded. */
bool cab_controls_enable_if_revision(CABControls *controls, uint64_t expected_revision);
void cab_controls_set_gains(CABControls *controls, float mic_gain,
                            float agent_gain, float monitor_gain);
CABControlsSnapshot cab_controls_snapshot(const CABControls *controls);
void cab_controls_set_monitor_agent_gain(CABControls *controls, float gain);
void cab_controls_set_limiter(CABControls *controls, bool enabled, float ceiling, float release_ms);

/* One output callback records; one worker consumes. Creation/destruction are
 * off the callback. A bounded SPSC queue carries complete block measurements,
 * never PCM. A slow reader drops telemetry only, not audio. All callback work
 * is bounded, allocation-free, and uses verified lock-free atomics. */
typedef struct CABPhoneOutputMeter CABPhoneOutputMeter;
typedef struct CABPhoneOutputSnapshot {
    /* Cumulative since creation, including blocks whose telemetry was dropped.
     * A shortage counts only while the corresponding effective route is on;
     * caller mute, startup mute and cancellation therefore add no shortages. */
    uint64_t microphone_underrun_frames;
    uint64_t agent_underrun_frames;
    /* Queue loss or callbacks whose invalid buffer layout cannot be measured. */
    uint64_t dropped_blocks;
    /* Since the previous take: complete rendered block measurements. Peak and
     * RMS describe actual post-mix samples, including muted/padded silence.
     * An increase in dropped_blocks means this level window is incomplete. */
    uint64_t rendered_frames;
    float peak;
    float rms;
    /* Virtual-device input delivered to this same duplex callback. This is
     * before Phone's processing, and delayed relative to the output above.
     * Zero frames means unavailable, not measured silence. All counts here
     * cover only this take's successfully queued callback blocks. */
    uint64_t readback_frames;
    uint64_t readback_zero_frames;
    uint64_t readback_unavailable_blocks;
    float readback_peak;
    float readback_rms;
} CABPhoneOutputSnapshot;
CABPhoneOutputMeter *cab_phone_output_meter_create(void);
void cab_phone_output_meter_destroy(CABPhoneOutputMeter *meter);
/* Call only for frames actually written to the device. NULL output is actual
 * silence. delivered counts come from each ring read before zero padding.
 * effective_routes must be the same controls snapshot used by the mixer. */
void cab_phone_output_meter_record(CABPhoneOutputMeter *meter, const float *output,
                                  size_t frames, size_t microphone_delivered,
                                  size_t agent_delivered, uint32_t effective_routes);
/* Same producer/queue as record; no additional IOProc. NULL readback means
 * unavailable regardless of readback_frames. Input and output frame counts
 * need not match, and their RMS denominators are independent. */
void cab_phone_output_meter_record_duplex(CABPhoneOutputMeter *meter, const float *output,
                                        size_t frames, size_t microphone_delivered,
                                        size_t agent_delivered, uint32_t effective_routes,
                                        const float *readback, size_t readback_frames);
/* Flag a callback whose output layout cannot be measured, without fabricating
 * sample counts or labeling intentional format rejection as source starvation. */
void cab_phone_output_meter_unavailable(CABPhoneOutputMeter *meter);
CABPhoneOutputSnapshot cab_phone_output_meter_take(CABPhoneOutputMeter *meter);

/* Null inputs are silence. Each output is optional. Inputs may alias one
 * output, but phone and agent_monitor must not alias each other. */
void cab_mix_mono(const float *microphone, const float *agent,
                  float *phone, float *agent_monitor, size_t frames,
                  float mic_gain, float agent_gain, float monitor_gain,
                  uint32_t routes);

/* Caller-facing peak limiter. State belongs to one output callback only. Scans
 * the current block before rendering, so it needs no lookahead queue or extra
 * latency. Attenuates the whole mix to a 0.98 ceiling, with immediate attack and
 * an 80 ms release.
 * Initialize before starting IO. Null inputs are silence; output may alias an
 * input. All processing is bounded and allocation-free. */
typedef struct CABPeakLimiter {
    float gain;
    float release_coefficient;
    float sample_rate;
    float ceiling;
    float release_ms;
} CABPeakLimiter;
void cab_peak_limiter_init(CABPeakLimiter *limiter, float sample_rate);
void cab_peak_limiter_configure(CABPeakLimiter *limiter, float ceiling, float release_ms);
void cab_mix_phone_limited(CABPeakLimiter *limiter, const float *microphone,
                           const float *source, float *output, size_t frames,
                           float mic_gain, float source_gain, uint32_t routes);

/* Owner-only agent speech is carried on a separate ring and can ONLY enter the
 * local monitor. The caller path above has no owner input. Caller audio follows
 * CALLER_TO_USER; both kinds of agent speech follow AGENT_TO_USER. */
void cab_mix_monitor(const float *caller, const float *agent, const float *owner,
                     float *output, size_t frames, float caller_gain,
                     float agent_gain, uint32_t routes);

/* Arithmetic mean across interleaved channels; each sample is sanitized first.
 * Null input or invalid channels (outside 1..64) produces silence. */
void cab_downmix_interleaved(const float *input, float *mono, size_t frames,
                            uint32_t channels);

#ifdef __cplusplus
}
#endif
#endif
