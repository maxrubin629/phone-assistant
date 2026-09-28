// Original Phone Assistant transport. Bounded, timestamp-addressed and nonblocking in IO.
#ifndef CODEX_CALL_LOOPBACK_H
#define CODEX_CALL_LOOPBACK_H
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <pthread.h>
#include <math.h>
#define CALL_RING_FRAMES 32768u
#define CALL_DELAY_FRAMES 512u
#define CALL_SAMPLE_RATE 48000u
#define CALL_TIMESTAMP_PERIOD 512u
static pthread_mutex_t callRingLock = PTHREAD_MUTEX_INITIALIZER;
static float callRing[CALL_RING_FRAMES][2];
static int64_t callFrame[CALL_RING_FRAMES];
static int64_t callLatestWriteEnd = INT64_MIN;
static void call_reset_locked(void) {
    for (unsigned i=0;i<CALL_RING_FRAMES;i++) callFrame[i]=INT64_MIN;
    callLatestWriteEnd=INT64_MIN;
}
// Only lifecycle/configuration callbacks call the blocking reset.
static void call_reset(void) {
    pthread_mutex_lock(&callRingLock);
    call_reset_locked();
    pthread_mutex_unlock(&callRingLock);
}
static bool call_valid_range(int64_t frame, uint32_t count) {
    return count <= CALL_RING_FRAMES && frame > INT64_MIN + CALL_DELAY_FRAMES &&
           frame <= INT64_MAX - (int64_t)count;
}
static float call_sample(float value, float gain) {
    if (!isfinite(value) || !isfinite(gain)) return 0;
    double scaled=(double)value*(double)gain;
    return (float)fmax(-1.0,fmin(1.0,scaled));
}
static bool call_write(int64_t frame, uint32_t count, const float *audio, float gain) {
    if (!audio || !call_valid_range(frame,count)) return false;
    if (pthread_mutex_trylock(&callRingLock)!=0) return false;
    if (frame < callLatestWriteEnd) call_reset_locked();
    for(uint32_t i=0;i<count;i++) {
        int64_t t=frame+i; unsigned slot=(uint64_t)t % CALL_RING_FRAMES;
        for(int channel=0;channel<2;channel++) callRing[slot][channel]=call_sample(audio[2*i+channel],gain);
        callFrame[slot]=t;
    }
    callLatestWriteEnd=frame+count;
    pthread_mutex_unlock(&callRingLock);
    return true;
}
static bool call_read(int64_t frame, uint32_t count, float *audio, float gain) {
    if (!audio || count > CALL_RING_FRAMES) return false;
    memset(audio,0,(size_t)count*2*sizeof(float));
    if (!call_valid_range(frame,count)) return false;
    if(pthread_mutex_trylock(&callRingLock)!=0) return false;
    for(uint32_t i=0;i<count;i++) {
        int64_t t=frame+i-CALL_DELAY_FRAMES;unsigned slot=(uint64_t)t % CALL_RING_FRAMES;
        // Reads never consume a slot, so independent readers get identical input.
        if(callFrame[slot]==t) for(int channel=0;channel<2;channel++) audio[2*i+channel]=call_sample(callRing[slot][channel],gain);
    }
    pthread_mutex_unlock(&callRingLock);
    return true;
}
#endif
