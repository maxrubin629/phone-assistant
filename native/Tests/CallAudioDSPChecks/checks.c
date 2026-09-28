#include "CallAudioDSP.h"

#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

static void equal(float actual, float expected) {
    assert(fabsf(actual - expected) < 0.000001f);
}

static void queue_checks(void) {
    assert(cab_ring_create(0, 1) == NULL);
    CABRing *ring = cab_ring_create(4, 1);
    assert(ring && cab_ring_capacity(ring) == 4);
    assert(cab_ring_queued_frames(NULL) == 0);
    assert(cab_ring_queued_frames(ring) == 0);
    float first[] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f};
    float out[6];
    assert(cab_ring_write(ring, first, 5, 1) == 4);
    assert(cab_ring_queued_frames(ring) == 4);
    assert(cab_ring_read(ring, out, 2, 1) == 2);
    assert(cab_ring_queued_frames(ring) == 2);
    equal(out[0], 0.1f); equal(out[1], 0.2f);
    assert(cab_ring_write(ring, first, 3, 1) == 2);
    assert(cab_ring_queued_frames(ring) == 4);
    assert(cab_ring_read(ring, out, 6, 1) == 4);
    assert(cab_ring_queued_frames(ring) == 0);
    equal(out[0], 0.3f); equal(out[1], 0.4f);
    equal(out[2], 0.1f); equal(out[3], 0.2f);
    equal(out[4], 0); equal(out[5], 0);
    CABRingCounters counts = cab_ring_counters(ring);
    assert(counts.accepted_frames == 6 && counts.delivered_frames == 6);
    assert(counts.overflow_frames == 2 && counts.underrun_frames == 2);

    assert(cab_ring_write(ring, first, 2, 1) == 2);
    cab_ring_set_generation(ring, 2);
    assert(cab_ring_queued_frames(ring) == 2);
    assert(cab_ring_generation(ring) == 2);
    assert(cab_ring_write(ring, first, 1, 1) == 0);
    float current[] = {0.7f, 0.8f};
    assert(cab_ring_write(ring, current, 2, 2) == 2);
    assert(cab_ring_read(ring, out, 3, 1) == 0);
    for (int i = 0; i < 3; ++i) equal(out[i], 0);
    assert(cab_ring_read(ring, out, 3, 2) == 2);
    assert(cab_ring_queued_frames(ring) == 0);
    equal(out[0], 0.7f); equal(out[1], 0.8f); equal(out[2], 0);
    counts = cab_ring_counters(ring);
    assert(counts.stale_frames == 2 && counts.rejected_generation_frames == 4);

    float bad[] = {NAN, INFINITY, -INFINITY, 7.0f};
    assert(cab_ring_write(ring, bad, 4, 2) == 4);
    assert(cab_ring_read(ring, out, 4, 2) == 4);
    equal(out[0], 0); equal(out[1], 0); equal(out[2], 0); equal(out[3], 1);
    cab_ring_destroy(ring);
}

static void mixer_checks(void) {
    float mic[] = {0.5f, NAN, -INFINITY};
    float agent[] = {0.25f, INFINITY, -2.0f};
    float phone[3], monitor[3];
    cab_mix_mono(mic, agent, phone, monitor, 3, 1, 1, 1, CAB_ROUTE_MIC_TO_CALLER);
    equal(phone[0], 0.5f); equal(monitor[0], 0);
    equal(phone[1], 0); equal(phone[2], 0);
    cab_mix_mono(mic, agent, phone, monitor, 3, 2, 2, 2, CAB_ROUTE_ALL);
    equal(phone[0], 1); equal(monitor[0], 0.5f);
    equal(phone[1], 0); equal(phone[2], -1);
    cab_mix_mono(mic, agent, phone, monitor, 3, NAN, INFINITY, -1, CAB_ROUTE_ALL);
    for (int i = 0; i < 3; ++i) { equal(phone[i], 0); equal(monitor[i], 0); }

    float caller[] = {0.1f, 0.1f, 0.1f};
    float owner[] = {0.2f, 0.2f, 0.2f};
    cab_mix_monitor(caller, agent, owner, monitor, 3, 1, 1, CAB_ROUTE_CALLER_TO_USER);
    equal(monitor[0], 0.1f);
    cab_mix_monitor(caller, agent, owner, monitor, 3, 1, 1, CAB_ROUTE_AGENT_TO_USER);
    equal(monitor[0], 0.45f);
    cab_mix_monitor(caller, agent, owner, monitor, 3, 1, 1, 0);
    equal(monitor[0], 0);

    float stereo[] = {0.2f, 0.6f, NAN, 0.2f, 8, -8};
    cab_downmix_interleaved(stereo, monitor, 3, 2);
    equal(monitor[0], 0.4f); equal(monitor[1], 0.1f); equal(monitor[2], 0);
    cab_downmix_interleaved(stereo, monitor, 3, 0);
    equal(monitor[0], 0);

    CABControls *controls = cab_controls_create();
    assert(controls);
    assert(cab_controls_revision(controls) == 1);
    cab_controls_set_gains(controls, NAN, 10, -1);
    cab_controls_set_routes(controls, 0xffffu);
    assert(cab_controls_routes(controls) == (CAB_ROUTE_ALL & ~(CAB_ROUTE_MIC_TO_CALLER | CAB_ROUTE_AGENT_TO_CALLER)));
    cab_controls_set_send_muted(controls, false);
    CABControlsSnapshot state = cab_controls_snapshot(controls);
    assert(state.routes == CAB_ROUTE_ALL);
    equal(state.mic_gain, 0); equal(state.agent_gain, 4); equal(state.monitor_gain, 0);
    cab_controls_set_enabled(controls, false);
    assert(cab_controls_routes(controls) == 0);
    assert(cab_controls_snapshot(controls).routes == 0);
    assert(cab_controls_enable_if_revision(controls, 1));
    assert(cab_controls_routes(controls) == CAB_ROUTE_ALL);
    cab_controls_cancel(controls);
    assert(cab_controls_revision(controls) == 2);
    assert(cab_controls_routes(controls) == 0);
    assert(!cab_controls_enable_if_revision(controls, 1));
    assert(cab_controls_routes(controls) == 0);
    assert(cab_controls_enable_if_revision(controls, 2));
    assert(cab_controls_routes(controls) == CAB_ROUTE_ALL);
    cab_controls_set_send_muted(controls, true);
    assert((cab_controls_snapshot(controls).routes & (CAB_ROUTE_MIC_TO_CALLER | CAB_ROUTE_AGENT_TO_CALLER)) == 0);
    cab_controls_destroy(controls);
}

typedef struct Stress {
    CABRing *ring;
    _Atomic int producer_done;
    _Atomic int reset_done;
    _Atomic uint64_t checked;
} Stress;

/* The sample is derived from its generation. Any stale sample escaping the
 * ring fails this check, even while resets race both endpoints. */
static float generation_sample(uint64_t generation) {
    return (float)(1 + generation % 1023) / 1024.0f;
}

static void *produce(void *context) {
    Stress *stress = context;
    for (size_t n = 0; n < 150000; ++n) {
        uint64_t epoch = cab_ring_generation(stress->ring);
        float sample[17];
        for (int i = 0; i < 17; ++i) sample[i] = generation_sample(epoch);
        cab_ring_write(stress->ring, sample, 17, epoch);
        if (n % 19 == 0) sched_yield();
    }
    atomic_store(&stress->producer_done, 1);
    return NULL;
}

static void *reset(void *context) {
    Stress *stress = context;
    for (uint64_t epoch = 2; epoch < 40000; ++epoch) {
        cab_ring_set_generation(stress->ring, epoch);
        if (epoch % 7 == 0) sched_yield();
    }
    atomic_store(&stress->reset_done, 1);
    return NULL;
}

static void *consume(void *context) {
    Stress *stress = context;
    while (!atomic_load(&stress->producer_done) || !atomic_load(&stress->reset_done)) {
        uint64_t epoch = cab_ring_generation(stress->ring);
        float samples[13];
        size_t count = cab_ring_read(stress->ring, samples, 13, epoch);
        for (size_t i = 0; i < count; ++i) equal(samples[i], generation_sample(epoch));
        for (size_t i = count; i < 13; ++i) equal(samples[i], 0);
        atomic_fetch_add(&stress->checked, count);
    }
    return NULL;
}

static void concurrent_checks(void) {
    Stress stress = { .ring = cab_ring_create(97, 1) };
    atomic_init(&stress.producer_done, 0);
    atomic_init(&stress.reset_done, 0);
    atomic_init(&stress.checked, 0);
    assert(stress.ring);
    pthread_t producer, resetter, consumer;
    assert(pthread_create(&consumer, NULL, consume, &stress) == 0);
    assert(pthread_create(&producer, NULL, produce, &stress) == 0);
    assert(pthread_create(&resetter, NULL, reset, &stress) == 0);
    assert(pthread_join(producer, NULL) == 0);
    assert(pthread_join(resetter, NULL) == 0);
    assert(pthread_join(consumer, NULL) == 0);
    assert(atomic_load(&stress.checked) > 0);
    cab_ring_destroy(stress.ring);
}

enum { ORDERED_FRAMES = 131072 };

static void *produce_ordered(void *context) {
    CABRing *ring = context;
    size_t next = 0;
    while (next < ORDERED_FRAMES) {
        float samples[19];
        size_t count = ORDERED_FRAMES - next;
        if (count > 19) count = 19;
        for (size_t i = 0; i < count; ++i)
            samples[i] = (float)(next + i) / (float)ORDERED_FRAMES;
        next += cab_ring_write(ring, samples, count, 1);
        if (next % 127 == 0) sched_yield();
    }
    return NULL;
}

static void ordered_checks(void) {
    CABRing *ring = cab_ring_create(97, 1);
    assert(ring);
    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce_ordered, ring) == 0);
    size_t next = 0;
    while (next < ORDERED_FRAMES) {
        float samples[23];
        size_t count = cab_ring_read(ring, samples, 23, 1);
        for (size_t i = 0; i < count; ++i)
            equal(samples[i], (float)(next + i) / (float)ORDERED_FRAMES);
        for (size_t i = count; i < 23; ++i) equal(samples[i], 0);
        next += count;
    }
    assert(pthread_join(producer, NULL) == 0);
    CABRingCounters counts = cab_ring_counters(ring);
    assert(counts.accepted_frames == ORDERED_FRAMES);
    assert(counts.delivered_frames == ORDERED_FRAMES);
    cab_ring_destroy(ring);
}

typedef struct LifecycleStress {
    CABControls *controls;
    _Atomic uint64_t request;
    _Atomic uint64_t revision;
    _Atomic uint64_t completed;
} LifecycleStress;

static void *complete_startup(void *context) {
    LifecycleStress *stress = context;
    for (uint64_t round = 1; round <= 10000; ++round) {
        while (atomic_load(&stress->request) != round) sched_yield();
        cab_controls_enable_if_revision(stress->controls, atomic_load(&stress->revision));
        atomic_store(&stress->completed, round);
    }
    return NULL;
}

static void lifecycle_checks(void) {
    LifecycleStress stress = { .controls = cab_controls_create() };
    atomic_init(&stress.request, 0);
    atomic_init(&stress.revision, 0);
    atomic_init(&stress.completed, 0);
    assert(stress.controls);
    cab_controls_set_routes(stress.controls, CAB_ROUTE_ALL);
    cab_controls_set_send_muted(stress.controls, false);
    pthread_t startup;
    assert(pthread_create(&startup, NULL, complete_startup, &stress) == 0);
    for (uint64_t round = 1; round <= 10000; ++round) {
        cab_controls_set_enabled(stress.controls, true);
        atomic_store(&stress.revision, cab_controls_revision(stress.controls));
        atomic_store(&stress.request, round);
        cab_controls_cancel(stress.controls);
        while (atomic_load(&stress.completed) != round) sched_yield();
        assert(cab_controls_routes(stress.controls) == 0);
        assert(cab_controls_snapshot(stress.controls).routes == 0);
        assert(cab_controls_revision(stress.controls) == round + 1);
    }
    assert(pthread_join(startup, NULL) == 0);
    cab_controls_destroy(stress.controls);
}

int main(void) {
    queue_checks();
    mixer_checks();
    ordered_checks();
    concurrent_checks();
    lifecycle_checks();
    puts("CallAudioDSP checks passed: ring boundaries, epochs, concurrent reset, finite samples, route isolation and cancellation race");
    return 0;
}
