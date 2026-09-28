#include "CallAudioDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(float) == sizeof(uint32_t), "DSP controls require 32-bit float");

typedef struct CABSlot {
    uint64_t generation;
    float sample;
} CABSlot;

struct CABRing {
    CABSlot *slots;
    size_t capacity;
    _Atomic uint64_t generation;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic uint64_t accepted_frames;
    _Atomic uint64_t delivered_frames;
    _Atomic uint64_t overflow_frames;
    _Atomic uint64_t stale_frames;
    _Atomic uint64_t underrun_frames;
    _Atomic uint64_t rejected_generation_frames;
};

struct CABControls {
    _Atomic uint32_t routes;
    _Atomic uint32_t send_muted;
    /* Low bit is enabled; upper 63 bits hold the cancellation revision. */
    _Atomic uint64_t lifecycle;
    _Atomic uint32_t mic_gain_bits;
    _Atomic uint32_t agent_gain_bits;
    _Atomic uint32_t monitor_gain_bits;
    _Atomic uint32_t monitor_agent_gain_bits;
    _Atomic uint32_t limiter_enabled;
    _Atomic uint32_t limiter_ceiling_bits;
    _Atomic uint32_t limiter_release_bits;
};

enum { CAB_PHONE_METER_CAPACITY = 1024 };
typedef struct CABPhoneOutputBlock {
    uint64_t frames;
    double sum_squares;
    float peak;
    uint64_t readback_frames;
    uint64_t readback_zero_frames;
    double readback_sum_squares;
    float readback_peak;
} CABPhoneOutputBlock;
struct CABPhoneOutputMeter {
    CABPhoneOutputBlock blocks[CAB_PHONE_METER_CAPACITY];
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic uint64_t microphone_underrun_frames;
    _Atomic uint64_t agent_underrun_frames;
    _Atomic uint64_t dropped_blocks;
};

static float finite_sample(float value) {
    if (!isfinite(value)) return 0.0f;
    if (value > 1.0f) return 1.0f;
    if (value < -1.0f) return -1.0f;
    return value;
}

static float bounded_gain(float value) {
    if (!isfinite(value) || value < 0.0f) return 0.0f;
    return value > 4.0f ? 4.0f : value;
}

static uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

CABRing *cab_ring_create(size_t capacity, uint64_t initial_generation) {
    if (capacity == 0 || capacity > (1u << 24)) return NULL;
    CABRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    atomic_init(&ring->generation, initial_generation);
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->accepted_frames, 0);
    atomic_init(&ring->delivered_frames, 0);
    atomic_init(&ring->overflow_frames, 0);
    atomic_init(&ring->stale_frames, 0);
    atomic_init(&ring->underrun_frames, 0);
    atomic_init(&ring->rejected_generation_frames, 0);
    if (!atomic_is_lock_free(&ring->generation) ||
        !atomic_is_lock_free(&ring->write_index)) {
        free(ring);
        return NULL;
    }
    ring->slots = calloc(capacity, sizeof(*ring->slots));
    if (!ring->slots) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity;
    return ring;
}

void cab_ring_destroy(CABRing *ring) {
    if (!ring) return;
    free(ring->slots);
    free(ring);
}

size_t cab_ring_capacity(const CABRing *ring) {
    return ring ? ring->capacity : 0;
}

size_t cab_ring_queued_frames(const CABRing *ring) {
    if (!ring) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    uint64_t queued = write - read;
    return queued > ring->capacity ? ring->capacity : (size_t)queued;
}

uint64_t cab_ring_generation(const CABRing *ring) {
    return ring ? atomic_load_explicit(&ring->generation, memory_order_acquire) : 0;
}

void cab_ring_set_generation(CABRing *ring, uint64_t generation) {
    if (ring) atomic_store_explicit(&ring->generation, generation, memory_order_release);
}

size_t cab_ring_write(CABRing *ring, const float *input, size_t frames,
                      uint64_t expected_generation) {
    if (!ring || !input || !frames) return 0;
    if (cab_ring_generation(ring) != expected_generation) {
        atomic_fetch_add_explicit(&ring->rejected_generation_frames, frames, memory_order_relaxed);
        return 0;
    }
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    size_t available = ring->capacity - (size_t)(write - read);
    size_t count = frames < available ? frames : available;
    for (size_t i = 0; i < count; ++i) {
        CABSlot *slot = &ring->slots[(write + i) % ring->capacity];
        slot->sample = finite_sample(input[i]);
        slot->generation = expected_generation;
    }
    /* Publishing even when reset raced is safe: the tags still describe the
     * old generation, which the consumer rejects. Only this producer writes
     * write_index, and only the consumer advances read_index. */
    atomic_store_explicit(&ring->write_index, write + count, memory_order_release);
    atomic_fetch_add_explicit(&ring->accepted_frames, count, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->overflow_frames, frames - count, memory_order_relaxed);
    return count;
}

size_t cab_ring_read(CABRing *ring, float *output, size_t frames,
                     uint64_t expected_generation) {
    if (!output || !frames) return 0;
    /* Callback callers are responsible for a valid, bounded output buffer. */
    memset(output, 0, frames * sizeof(*output));
    if (!ring) return 0;
    if (cab_ring_generation(ring) != expected_generation) {
        atomic_fetch_add_explicit(&ring->rejected_generation_frames, frames, memory_order_relaxed);
        return 0;
    }
    uint64_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    size_t delivered = 0;
    size_t stale = 0;
    /* The write snapshot bounds this loop by capacity, even if a producer
     * continues publishing while the consumer drains obsolete samples. */
    while (read != write && delivered < frames) {
        const CABSlot *slot = &ring->slots[read % ring->capacity];
        if (slot->generation == expected_generation) {
            output[delivered++] = slot->sample;
        } else {
            /* A concurrent reset may have published NEW-generation samples
             * after our entry check. Never discard those on an old read. */
            if (cab_ring_generation(ring) != expected_generation) break;
            ++stale;
        }
        ++read;
    }
    atomic_store_explicit(&ring->read_index, read, memory_order_release);
    atomic_fetch_add_explicit(&ring->stale_frames, stale, memory_order_relaxed);
    if (cab_ring_generation(ring) != expected_generation) {
        memset(output, 0, frames * sizeof(*output));
        atomic_fetch_add_explicit(&ring->stale_frames, delivered, memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->rejected_generation_frames, frames, memory_order_relaxed);
        return 0;
    }
    atomic_fetch_add_explicit(&ring->delivered_frames, delivered, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->underrun_frames, frames - delivered, memory_order_relaxed);
    return delivered;
}

CABRingCounters cab_ring_counters(const CABRing *ring) {
    CABRingCounters result = {0};
    if (!ring) return result;
#define LOAD_COUNTER(name) result.name = atomic_load_explicit(&ring->name, memory_order_relaxed)
    LOAD_COUNTER(accepted_frames);
    LOAD_COUNTER(delivered_frames);
    LOAD_COUNTER(overflow_frames);
    LOAD_COUNTER(stale_frames);
    LOAD_COUNTER(underrun_frames);
    LOAD_COUNTER(rejected_generation_frames);
#undef LOAD_COUNTER
    return result;
}

CABControls *cab_controls_create(void) {
    CABControls *controls = calloc(1, sizeof(*controls));
    if (!controls) return NULL;
    atomic_init(&controls->routes, 0);
    atomic_init(&controls->send_muted, 1);
    atomic_init(&controls->lifecycle, 3); /* revision 1, enabled */
    atomic_init(&controls->mic_gain_bits, float_bits(1.0f));
    atomic_init(&controls->agent_gain_bits, float_bits(1.0f));
    atomic_init(&controls->monitor_gain_bits, float_bits(1.0f));
    atomic_init(&controls->monitor_agent_gain_bits, float_bits(1.0f));
    atomic_init(&controls->limiter_enabled, 1);
    atomic_init(&controls->limiter_ceiling_bits, float_bits(0.98f));
    atomic_init(&controls->limiter_release_bits, float_bits(80.0f));
    if (!atomic_is_lock_free(&controls->routes) ||
        !atomic_is_lock_free(&controls->mic_gain_bits) ||
        !atomic_is_lock_free(&controls->lifecycle)) {
        free(controls);
        return NULL;
    }
    return controls;
}

void cab_controls_destroy(CABControls *controls) { free(controls); }

void cab_controls_set_routes(CABControls *controls, uint32_t routes) {
    if (controls) atomic_store_explicit(&controls->routes, routes & CAB_ROUTE_ALL, memory_order_release);
}

uint32_t cab_controls_routes(const CABControls *controls) {
    if (!controls) return 0;
    uint32_t routes = atomic_load_explicit(&controls->routes, memory_order_acquire);
    if (atomic_load_explicit(&controls->send_muted, memory_order_acquire))
        routes &= ~(CAB_ROUTE_MIC_TO_CALLER | CAB_ROUTE_AGENT_TO_CALLER);
    if (!(atomic_load_explicit(&controls->lifecycle, memory_order_acquire) & 1u))
        return 0;
    return routes;
}

void cab_controls_set_send_muted(CABControls *controls, bool muted) {
    if (controls) atomic_store_explicit(&controls->send_muted, muted ? 1u : 0u, memory_order_release);
}

void cab_controls_set_enabled(CABControls *controls, bool enabled) {
    if (!controls) return;
    uint64_t old = atomic_load_explicit(&controls->lifecycle, memory_order_relaxed);
    uint64_t next;
    do {
        next = (old & ~UINT64_C(1)) | (enabled ? UINT64_C(1) : UINT64_C(0));
    } while (!atomic_compare_exchange_weak_explicit(&controls->lifecycle, &old, next,
                                                   memory_order_release, memory_order_relaxed));
}

void cab_controls_cancel(CABControls *controls) {
    if (!controls) return;
    uint64_t old = atomic_load_explicit(&controls->lifecycle, memory_order_relaxed);
    uint64_t next;
    do {
        next = (old & ~UINT64_C(1)) + UINT64_C(2);
    } while (!atomic_compare_exchange_weak_explicit(&controls->lifecycle, &old, next,
                                                   memory_order_acq_rel, memory_order_relaxed));
}

uint64_t cab_controls_revision(const CABControls *controls) {
    return controls ? atomic_load_explicit(&controls->lifecycle, memory_order_acquire) >> 1 : 0;
}

bool cab_controls_enable_if_revision(CABControls *controls, uint64_t expected_revision) {
    if (!controls || expected_revision > (UINT64_MAX >> 1)) return false;
    uint64_t old = atomic_load_explicit(&controls->lifecycle, memory_order_acquire);
    do {
        if ((old >> 1) != expected_revision) return false;
    } while (!atomic_compare_exchange_weak_explicit(&controls->lifecycle, &old, old | UINT64_C(1),
                                                   memory_order_acq_rel, memory_order_acquire));
    return true;
}

void cab_controls_set_gains(CABControls *controls, float mic_gain,
                            float agent_gain, float monitor_gain) {
    if (!controls) return;
    atomic_store_explicit(&controls->mic_gain_bits, float_bits(bounded_gain(mic_gain)), memory_order_relaxed);
    atomic_store_explicit(&controls->agent_gain_bits, float_bits(bounded_gain(agent_gain)), memory_order_relaxed);
    atomic_store_explicit(&controls->monitor_gain_bits, float_bits(bounded_gain(monitor_gain)), memory_order_relaxed);
    cab_controls_set_monitor_agent_gain(controls, agent_gain);
}

void cab_controls_set_monitor_agent_gain(CABControls *controls, float gain) {
    if (controls) atomic_store_explicit(&controls->monitor_agent_gain_bits, float_bits(bounded_gain(gain)), memory_order_relaxed);
}
void cab_controls_set_limiter(CABControls *controls, bool enabled, float ceiling, float release_ms) {
    if (!controls) return;
    ceiling = isfinite(ceiling) ? fminf(0.999f, fmaxf(0.1f, ceiling)) : 0.98f;
    release_ms = isfinite(release_ms) ? fminf(1000.0f, fmaxf(10.0f, release_ms)) : 80.0f;
    atomic_store_explicit(&controls->limiter_ceiling_bits, float_bits(ceiling), memory_order_relaxed);
    atomic_store_explicit(&controls->limiter_release_bits, float_bits(release_ms), memory_order_relaxed);
    atomic_store_explicit(&controls->limiter_enabled, enabled ? 1u : 0u, memory_order_relaxed);
}

CABControlsSnapshot cab_controls_snapshot(const CABControls *controls) {
    CABControlsSnapshot result = {0};
    if (!controls) return result;
    result.routes = cab_controls_routes(controls);
    result.mic_gain = bits_float(atomic_load_explicit(&controls->mic_gain_bits, memory_order_relaxed));
    result.agent_gain = bits_float(atomic_load_explicit(&controls->agent_gain_bits, memory_order_relaxed));
    result.monitor_gain = bits_float(atomic_load_explicit(&controls->monitor_gain_bits, memory_order_relaxed));
    result.monitor_agent_gain = bits_float(atomic_load_explicit(&controls->monitor_agent_gain_bits, memory_order_relaxed));
    result.limiter_enabled = atomic_load_explicit(&controls->limiter_enabled, memory_order_relaxed);
    result.limiter_ceiling = bits_float(atomic_load_explicit(&controls->limiter_ceiling_bits, memory_order_relaxed));
    result.limiter_release_ms = bits_float(atomic_load_explicit(&controls->limiter_release_bits, memory_order_relaxed));
    return result;
}

CABPhoneOutputMeter *cab_phone_output_meter_create(void) {
    CABPhoneOutputMeter *meter = calloc(1, sizeof(*meter));
    if (!meter) return NULL;
    atomic_init(&meter->read_index, 0);
    atomic_init(&meter->write_index, 0);
    atomic_init(&meter->microphone_underrun_frames, 0);
    atomic_init(&meter->agent_underrun_frames, 0);
    atomic_init(&meter->dropped_blocks, 0);
    if (!atomic_is_lock_free(&meter->read_index) ||
        !atomic_is_lock_free(&meter->write_index) ||
        !atomic_is_lock_free(&meter->microphone_underrun_frames) ||
        !atomic_is_lock_free(&meter->agent_underrun_frames) ||
        !atomic_is_lock_free(&meter->dropped_blocks)) {
        free(meter);
        return NULL;
    }
    return meter;
}

void cab_phone_output_meter_destroy(CABPhoneOutputMeter *meter) { free(meter); }

void cab_phone_output_meter_unavailable(CABPhoneOutputMeter *meter) {
    if (meter) atomic_fetch_add_explicit(&meter->dropped_blocks, 1, memory_order_relaxed);
}

void cab_phone_output_meter_record(CABPhoneOutputMeter *meter, const float *output,
                                  size_t frames, size_t microphone_delivered,
                                  size_t agent_delivered, uint32_t effective_routes) {
    cab_phone_output_meter_record_duplex(meter, output, frames, microphone_delivered,
                                        agent_delivered, effective_routes, NULL, 0);
}

void cab_phone_output_meter_record_duplex(CABPhoneOutputMeter *meter, const float *output,
                                        size_t frames, size_t microphone_delivered,
                                        size_t agent_delivered, uint32_t effective_routes,
                                        const float *readback, size_t readback_frames) {
    if (!meter || !frames) return;
    if ((effective_routes & CAB_ROUTE_MIC_TO_CALLER) && microphone_delivered < frames)
        atomic_fetch_add_explicit(&meter->microphone_underrun_frames,
                                  frames - microphone_delivered, memory_order_relaxed);
    if ((effective_routes & CAB_ROUTE_AGENT_TO_CALLER) && agent_delivered < frames)
        atomic_fetch_add_explicit(&meter->agent_underrun_frames,
                                  frames - agent_delivered, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&meter->write_index, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&meter->read_index, memory_order_acquire);
    if (write - read == CAB_PHONE_METER_CAPACITY) {
        cab_phone_output_meter_unavailable(meter);
        return;
    }
    CABPhoneOutputBlock block = { .frames = frames, .sum_squares = 0, .peak = 0 };
    if (output) {
        for (size_t frame = 0; frame < frames; ++frame) {
            float sample = finite_sample(output[frame]);
            block.peak = fmaxf(block.peak, fabsf(sample));
            block.sum_squares += (double)sample * sample;
        }
    }
    if (readback) {
        block.readback_frames = readback_frames;
        for (size_t frame = 0; frame < readback_frames; ++frame) {
            float sample = finite_sample(readback[frame]);
            block.readback_peak = fmaxf(block.readback_peak, fabsf(sample));
            block.readback_sum_squares += (double)sample * sample;
            if (sample == 0) ++block.readback_zero_frames;
        }
    }
    meter->blocks[write % CAB_PHONE_METER_CAPACITY] = block;
    atomic_store_explicit(&meter->write_index, write + 1, memory_order_release);
}

CABPhoneOutputSnapshot cab_phone_output_meter_take(CABPhoneOutputMeter *meter) {
    CABPhoneOutputSnapshot result = {0};
    if (!meter) return result;
    uint64_t read = atomic_load_explicit(&meter->read_index, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&meter->write_index, memory_order_acquire);
    double sum_squares = 0, readback_sum_squares = 0;
    /* The single write snapshot bounds this loop to the queue capacity. */
    while (read != write) {
        const CABPhoneOutputBlock block = meter->blocks[read % CAB_PHONE_METER_CAPACITY];
        result.rendered_frames += block.frames;
        result.peak = fmaxf(result.peak, block.peak);
        sum_squares += block.sum_squares;
        result.readback_frames += block.readback_frames;
        result.readback_zero_frames += block.readback_zero_frames;
        if (!block.readback_frames) ++result.readback_unavailable_blocks;
        result.readback_peak = fmaxf(result.readback_peak, block.readback_peak);
        readback_sum_squares += block.readback_sum_squares;
        ++read;
    }
    atomic_store_explicit(&meter->read_index, read, memory_order_release);
    result.rms = result.rendered_frames ? (float)sqrt(sum_squares / result.rendered_frames) : 0;
    result.readback_rms = result.readback_frames ? (float)sqrt(readback_sum_squares / result.readback_frames) : 0;
    /* Lifetime counters are independent observations and may include a just-
     * completed callback after the level-window boundary. */
    result.microphone_underrun_frames = atomic_load_explicit(&meter->microphone_underrun_frames, memory_order_relaxed);
    result.agent_underrun_frames = atomic_load_explicit(&meter->agent_underrun_frames, memory_order_relaxed);
    result.dropped_blocks = atomic_load_explicit(&meter->dropped_blocks, memory_order_relaxed);
    return result;
}

void cab_mix_mono(const float *microphone, const float *agent,
                  float *phone, float *agent_monitor, size_t frames,
                  float mic_gain, float agent_gain, float monitor_gain,
                  uint32_t routes) {
    float mg = routes & CAB_ROUTE_MIC_TO_CALLER ? bounded_gain(mic_gain) : 0.0f;
    float ag = routes & CAB_ROUTE_AGENT_TO_CALLER ? bounded_gain(agent_gain) : 0.0f;
    float mon = routes & CAB_ROUTE_AGENT_TO_USER ? bounded_gain(monitor_gain) : 0.0f;
    for (size_t i = 0; i < frames; ++i) {
        float m = microphone ? finite_sample(microphone[i]) : 0.0f;
        float a = agent ? finite_sample(agent[i]) : 0.0f;
        if (phone) phone[i] = finite_sample(m * mg + a * ag);
        if (agent_monitor) agent_monitor[i] = finite_sample(a * mon);
    }
}

void cab_peak_limiter_init(CABPeakLimiter *limiter, float sample_rate) {
    if (!limiter) return;
    if (!isfinite(sample_rate) || sample_rate < 8000 || sample_rate > 384000)
        sample_rate = 48000;
    limiter->gain = 1.0f;
    limiter->sample_rate = sample_rate;
    limiter->ceiling = 0.98f;
    limiter->release_ms = 80.0f;
    limiter->release_coefficient = expf(-1.0f / (0.080f * sample_rate));
}

void cab_peak_limiter_configure(CABPeakLimiter *limiter, float ceiling, float release_ms) {
    if (!limiter) return;
    ceiling = isfinite(ceiling) ? fminf(0.999f, fmaxf(0.1f, ceiling)) : 0.98f;
    release_ms = isfinite(release_ms) ? fminf(1000.0f, fmaxf(10.0f, release_ms)) : 80.0f;
    limiter->ceiling = ceiling;
    if (limiter->release_ms != release_ms) {
        limiter->release_ms = release_ms;
        limiter->release_coefficient = expf(-1.0f / (0.001f * release_ms * limiter->sample_rate));
    }
}

void cab_mix_phone_limited(CABPeakLimiter *limiter, const float *microphone,
                           const float *source, float *output, size_t frames,
                           float mic_gain, float source_gain, uint32_t routes) {
    if (!output) return;
    if (!limiter) { memset(output, 0, frames * sizeof(*output)); return; }
    const float ceiling = limiter->ceiling;
    float mg = routes & CAB_ROUTE_MIC_TO_CALLER ? bounded_gain(mic_gain) : 0.0f;
    float sg = routes & CAB_ROUTE_AGENT_TO_CALLER ? bounded_gain(source_gain) : 0.0f;
    float peak = 0.0f;
    for (size_t i = 0; i < frames; ++i) {
        float m = microphone ? finite_sample(microphone[i]) : 0.0f;
        float s = source ? finite_sample(source[i]) : 0.0f;
        output[i] = m * mg + s * sg;
        peak = fmaxf(peak, fabsf(output[i]));
    }
    if (mg == 0.0f && sg == 0.0f) { limiter->gain = 1.0f; return; }
    float required = peak > ceiling ? ceiling / peak : 1.0f;
    float gain = fminf(required, limiter->gain);
    for (size_t i = 0; i < frames; ++i) {
        gain = fminf(required, 1.0f - (1.0f - gain) * limiter->release_coefficient);
        output[i] = finite_sample(output[i] * gain);
    }
    limiter->gain = gain;
}

void cab_downmix_interleaved(const float *input, float *mono, size_t frames,
                            uint32_t channels) {
    if (!mono) return;
    if (!input || channels < 1 || channels > 64) {
        memset(mono, 0, frames * sizeof(*mono));
        return;
    }
    for (size_t frame = 0; frame < frames; ++frame) {
        float sum = 0.0f;
        for (uint32_t channel = 0; channel < channels; ++channel)
            sum += finite_sample(input[frame * channels + channel]);
        mono[frame] = finite_sample(sum / (float)channels);
    }
}

void cab_mix_monitor(const float *caller, const float *agent, const float *owner,
                     float *output, size_t frames, float caller_gain,
                     float agent_gain, uint32_t routes) {
    if (!output) return;
    float cg = routes & CAB_ROUTE_CALLER_TO_USER ? bounded_gain(caller_gain) : 0.0f;
    float ag = routes & CAB_ROUTE_AGENT_TO_USER ? bounded_gain(agent_gain) : 0.0f;
    for (size_t i = 0; i < frames; ++i) {
        float c = caller ? finite_sample(caller[i]) : 0.0f;
        float a = agent ? finite_sample(agent[i]) : 0.0f;
        float o = owner ? finite_sample(owner[i]) : 0.0f;
        output[i] = finite_sample(c * cg + (a + o) * ag);
    }
}
