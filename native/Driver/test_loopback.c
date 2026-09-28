#include "Loopback.h"
#include <assert.h>
#include <stdio.h>
#include <float.h>
static void silent(const float *v, unsigned n) { for(unsigned i=0;i<n;i++) assert(v[i]==0); }
int main(void) {
    float input[]={0.25f,-0.5f,1.0f,-1.0f}, output[4];
    call_reset();call_read(512,2,output,1);assert(output[0]==0);
    call_write(0,2,input,1);call_read(512,2,output,0.5f);
    assert(output[0]==0.125f && output[1]==-0.25f && output[2]==0.5f);
    call_read(CALL_RING_FRAMES+512,2,output,1);assert(output[0]==0);
    call_write(CALL_RING_FRAMES-1,2,input,1);call_read(CALL_RING_FRAMES-1+512,2,output,1);assert(output[2]==1);
    call_reset();call_read(CALL_RING_FRAMES-1+512,2,output,1);assert(output[2]==0);
    // Multiple readers can read the same time without consuming or clearing it.
    call_write(10,2,input,1);call_read(522,2,output,1);
    assert(memcmp(input,output,sizeof(input))==0);
    call_read(522,2,output,1);assert(memcmp(input,output,sizeof(input))==0);
    // A gap and an overwritten slot both produce silence instead of old audio.
    call_read(524,2,output,1);silent(output,4);
    call_write(10+CALL_RING_FRAMES,2,input,1);
    call_read(522,2,output,1);silent(output,4);
    // Timeline rewind invalidates previous future samples.
    call_write(9,2,input,1);call_read(522+CALL_RING_FRAMES,2,output,1);silent(output,4);
    // Realtime lock contention must return immediately, with silent input.
    pthread_mutex_lock(&callRingLock);
    assert(!call_read(521,2,output,1));silent(output,4);
    assert(!call_write(11,2,input,1));
    pthread_mutex_unlock(&callRingLock);
    call_read(523,2,output,1);silent(output,4);
    float invalid[]={NAN,INFINITY,-INFINITY,FLT_MAX};
    call_write(100,2,invalid,2);call_read(612,2,output,1);
    silent(output,3);assert(output[3]==1);
    call_read(612,2,output,NAN);silent(output,4);
    call_write(102,2,input,NAN);call_read(614,2,output,1);silent(output,4);
    // Signed sample times are valid; extreme arithmetic must not overflow.
    call_reset();call_write(-10,2,input,1);call_read(502,2,output,1);
    assert(memcmp(input,output,sizeof(input))==0);
    assert(!call_write(INT64_MAX,2,input,1));
    assert(!call_read(INT64_MIN,2,output,1));silent(output,4);
    assert(!call_write(0,CALL_RING_FRAMES+1,input,1));
    puts("Transport: silence, wrap, independent readers, gaps, rewind, contention, finite samples and bounds passed");
    return 0;
}
