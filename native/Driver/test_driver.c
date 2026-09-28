#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
static OSStatus storage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *data) { *data=NULL;return noErr; }
static OSStatus changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) { return noErr; }
static AudioServerPlugInDriverRef driver;
static void get(AudioObjectID o, AudioObjectPropertySelector key, AudioObjectPropertyScope scope, void *data, UInt32 bytes) {
    AudioObjectPropertyAddress a={key,scope,kAudioObjectPropertyElementMain}; UInt32 size=0;
    assert((*driver)->HasProperty(driver,o,0,&a));
    assert((*driver)->GetPropertyDataSize(driver,o,0,&a,0,NULL,&size)==noErr);
    assert(size==bytes);
    assert((*driver)->GetPropertyData(driver,o,0,&a,0,NULL,bytes,&size,data)==noErr && size==bytes);
}
static OSStatus set(AudioObjectID o, AudioObjectPropertySelector key, const void *value, UInt32 size) {
    AudioObjectPropertyAddress a={key,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return (*driver)->SetPropertyData(driver,o,0,&a,0,NULL,size,value);
}
static void silent(float *audio, size_t n) { for(size_t i=0;i<n;i++) assert(audio[i]==0); }
static void check_volume_contract(void) {
    // Exercise the exported HAL interface and actual PCM, not just a helper.
    // Half hardware volume must retain ~one-quarter amplitude, not -72 dB.
    const float scalars[]={0,0.25f,0.5f,0.75f,0.9f,1};
    const float expectedGains[]={0.0006309573f,0.06309152f,0.25047321f,0.56277603f,0.81011987f,1};
    float unity=1, source[2]={0.25f,-0.5f}, result[2];
    AudioServerPlugInIOCycleInfo cycle={0};
    cycle.mOutputTime.mFlags=cycle.mInputTime.mFlags=kAudioTimeStampSampleTimeValid;
    double time=100000;
    for(unsigned direction=0;direction<2;direction++) {
        AudioObjectID control=direction==0?5:9, other=direction==0?9:5;
        assert(set(other,kAudioLevelControlPropertyScalarValue,&unity,sizeof(unity))==noErr);
        AudioObjectPropertyScope scope;
        get(control,kAudioControlPropertyScope,kAudioObjectPropertyScopeGlobal,&scope,sizeof(scope));
        assert(scope==(direction==0?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput));
        AudioValueRange range;
        get(control,kAudioLevelControlPropertyDecibelRange,kAudioObjectPropertyScopeGlobal,&range,sizeof(range));
        assert(range.mMinimum==-64 && range.mMaximum==0);
        for(unsigned j=0;j<sizeof(scalars)/sizeof(scalars[0]);j++) {
            float scalar=scalars[j], stored=0, db=0, converted=scalar, roundTrip;
            assert(set(control,kAudioLevelControlPropertyScalarValue,&scalar,sizeof(scalar))==noErr);
            get(control,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,&stored,sizeof(stored));
            get(control,kAudioLevelControlPropertyDecibelValue,kAudioObjectPropertyScopeGlobal,&db,sizeof(db));
            get(control,kAudioLevelControlPropertyConvertScalarToDecibels,kAudioObjectPropertyScopeGlobal,&converted,sizeof(converted));
            roundTrip=converted;
            get(control,kAudioLevelControlPropertyConvertDecibelsToScalar,kAudioObjectPropertyScopeGlobal,&roundTrip,sizeof(roundTrip));
            assert(stored==scalar && fabsf(roundTrip-scalar)<0.00001f && fabsf(db-converted)<0.00001f);
            // Setting the reported dB must restore the same scalar and PCM.
            float low=-64;
            assert(set(control,kAudioLevelControlPropertyDecibelValue,&low,sizeof(low))==noErr);
            assert(set(control,kAudioLevelControlPropertyDecibelValue,&db,sizeof(db))==noErr);
            get(control,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,&stored,sizeof(stored));
            assert(fabsf(stored-scalar)<0.00001f);
            time+=8;cycle.mOutputTime.mSampleTime=time;cycle.mInputTime.mSampleTime=time+512;
            assert((*driver)->DoIOOperation(driver,13,8,1,kAudioServerPlugInIOOperationWriteMix,1,&cycle,source,NULL)==noErr);
            assert((*driver)->DoIOOperation(driver,3,4,1,kAudioServerPlugInIOOperationReadInput,1,&cycle,result,NULL)==noErr);
            for(unsigned channel=0;channel<2;channel++) {
                assert(fabsf(result[channel]/source[channel]-expectedGains[j])<0.000001f);
                assert(fabsf(result[channel]/source[channel]-powf(10,db/20))<0.000001f);
            }
            if(scalar==1) assert(memcmp(source,result,sizeof(source))==0);
        }
        for(unsigned bad=0;bad<2;bad++) {
            float value=bad==0?NAN:INFINITY;
            assert(set(control,kAudioLevelControlPropertyScalarValue,&value,sizeof(value))!=noErr);
            assert(set(control,kAudioLevelControlPropertyDecibelValue,&value,sizeof(value))!=noErr);
            const AudioObjectPropertySelector conversions[]={kAudioLevelControlPropertyConvertScalarToDecibels,kAudioLevelControlPropertyConvertDecibelsToScalar};
            for(unsigned c=0;c<2;c++) {
                AudioObjectPropertyAddress address={conversions[c],kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
                UInt32 size=sizeof(value);
                assert((*driver)->GetPropertyData(driver,control,0,&address,0,NULL,sizeof(value),&size,&value)!=noErr);
            }
        }
        float retained=0;
        get(control,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,&retained,sizeof(retained));
        assert(retained==1); // Rejected requests must not mutate the control.
        const float outsideScalars[]={-1,2}, clampedScalars[]={0,1};
        const float outsideDecibels[]={-100,6};
        for(unsigned j=0;j<2;j++) {
            assert(set(control,kAudioLevelControlPropertyScalarValue,&outsideScalars[j],sizeof(float))==noErr);
            get(control,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,&retained,sizeof(retained));
            assert(retained==clampedScalars[j]);
            assert(set(control,kAudioLevelControlPropertyDecibelValue,&outsideDecibels[j],sizeof(float))==noErr);
            get(control,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,&retained,sizeof(retained));
            assert(retained==clampedScalars[j]);
        }
        assert(set(control,kAudioLevelControlPropertyScalarValue,&unity,sizeof(unity))==noErr);
        AudioObjectID muteControl=direction==0?6:10;
        UInt32 muted=1;
        assert(set(muteControl,kAudioBooleanControlPropertyValue,&muted,sizeof(muted))==noErr);
        time+=8;cycle.mOutputTime.mSampleTime=time;cycle.mInputTime.mSampleTime=time+512;
        assert((*driver)->DoIOOperation(driver,13,8,1,kAudioServerPlugInIOOperationWriteMix,1,&cycle,source,NULL)==noErr);
        assert((*driver)->DoIOOperation(driver,3,4,1,kAudioServerPlugInIOOperationReadInput,1,&cycle,result,NULL)==noErr);
        silent(result,2);
        muted=0;
        assert(set(muteControl,kAudioBooleanControlPropertyValue,&muted,sizeof(muted))==noErr);
        time+=8;cycle.mOutputTime.mSampleTime=time;cycle.mInputTime.mSampleTime=time+512;
        assert((*driver)->DoIOOperation(driver,13,8,1,kAudioServerPlugInIOOperationWriteMix,1,&cycle,source,NULL)==noErr);
        assert((*driver)->DoIOOperation(driver,3,4,1,kAudioServerPlugInIOOperationReadInput,1,&cycle,result,NULL)==noErr);
        assert(memcmp(source,result,sizeof(source))==0);
    }
}

static void check_split_devices(void) {
    const AudioObjectPropertyScope global=kAudioObjectPropertyScopeGlobal;
    const AudioObjectPropertyScope input=kAudioObjectPropertyScopeInput, output=kAudioObjectPropertyScopeOutput;
    AudioObjectID ids[4]={0}, owner=0; UInt32 flag=0;
    get(kAudioObjectPlugInObject,kAudioPlugInPropertyDeviceList,global,ids,2*sizeof(AudioObjectID));
    assert(ids[0]==3 && ids[1]==13);
    get(kAudioObjectPlugInObject,kAudioObjectPropertyOwnedObjects,global,ids,3*sizeof(AudioObjectID));
    assert(ids[0]==2 && ids[1]==3 && ids[2]==13);
    get(2,kAudioBoxPropertyDeviceList,global,ids,2*sizeof(AudioObjectID));
    assert(ids[0]==3 && ids[1]==13);
    for(unsigned device=3;device<=13;device+=10) {
        unsigned first=device==3?4:8;
        get(device,kAudioDevicePropertyStreams,global,ids,sizeof(AudioObjectID)); assert(ids[0]==first);
        get(device,kAudioDevicePropertyStreams,device==3?output:input,ids,0);
        get(device,kAudioObjectPropertyControlList,global,ids,3*sizeof(AudioObjectID));
        for(unsigned i=0;i<3;i++) assert(ids[i]==first+1+i);
        get(device,kAudioObjectPropertyOwnedObjects,global,ids,4*sizeof(AudioObjectID));
        for(unsigned i=0;i<4;i++) {
            assert(ids[i]==first+i);
            get(ids[i],kAudioObjectPropertyOwner,global,&owner,sizeof(owner)); assert(owner==device);
        }
        get(device,kAudioDevicePropertyIsHidden,global,&flag,sizeof(flag)); assert(flag==(device==13));
        get(device,kAudioDevicePropertyDeviceCanBeDefaultDevice,output,&flag,sizeof(flag)); assert(flag==0);
        get(device,kAudioDevicePropertyDeviceCanBeDefaultDevice,input,&flag,sizeof(flag)); assert(flag==(device==3));
        CFStringRef uid=NULL;
        get(device,kAudioDevicePropertyDeviceUID,global,&uid,sizeof(uid));
        assert(CFEqual(uid,device==3?CFSTR("com.codexcall.audio.send.device"):CFSTR("com.codexcall.audio.send.feed")));
        AudioObjectPropertyAddress a={kAudioPlugInPropertyTranslateUIDToDevice,global,0}; UInt32 size=sizeof(owner);
        assert((*driver)->GetPropertyData(driver,kAudioObjectPlugInObject,0,&a,sizeof(uid),&uid,sizeof(owner),&size,&owner)==noErr);
        assert(owner==device); CFRelease(uid);
        Boolean will=false,inplace=false;
        assert((*driver)->WillDoIOOperation(driver,device,1,kAudioServerPlugInIOOperationWriteMix,&will,&inplace)==noErr);
        assert(will==(device==13));
        assert((*driver)->WillDoIOOperation(driver,device,1,kAudioServerPlugInIOOperationReadInput,&will,&inplace)==noErr);
        assert(will==(device==3));
    }
    // Feed first, then two readers. All retain the same clock origin/seed.
    assert((*driver)->StartIO(driver,13,10)==noErr);
    Float64 sample1,sample2; UInt64 host1,host2,seed1,seed2;
    assert((*driver)->GetZeroTimeStamp(driver,13,10,&sample1,&host1,&seed1)==noErr);
    assert((*driver)->StartIO(driver,3,11)==noErr);
    assert((*driver)->StartIO(driver,3,12)==noErr);
    assert((*driver)->GetZeroTimeStamp(driver,3,11,&sample2,&host2,&seed2)==noErr);
    assert(seed1==seed2 && sample2>=sample1);
    AudioServerPlugInIOCycleInfo cycle={0};
    cycle.mOutputTime.mFlags=cycle.mInputTime.mFlags=kAudioTimeStampSampleTimeValid;
    cycle.mOutputTime.mSampleTime=4096;cycle.mInputTime.mSampleTime=4608;
    float source[4]={0.25,-0.5,0.75,-0.8}, result[4];
    assert((*driver)->DoIOOperation(driver,3,8,10,kAudioServerPlugInIOOperationWriteMix,2,&cycle,source,NULL)!=noErr);
    assert((*driver)->DoIOOperation(driver,13,4,11,kAudioServerPlugInIOOperationReadInput,2,&cycle,result,NULL)!=noErr);
    assert((*driver)->DoIOOperation(driver,13,8,10,kAudioServerPlugInIOOperationWriteMix,2,&cycle,source,NULL)==noErr);
    for(unsigned reader=11;reader<=12;reader++) {
        assert((*driver)->DoIOOperation(driver,3,4,reader,kAudioServerPlugInIOOperationReadInput,2,&cycle,result,NULL)==noErr);
        assert(memcmp(source,result,sizeof(source))==0);
    }
    assert((*driver)->StopIO(driver,3,11)==noErr);
    assert((*driver)->DoIOOperation(driver,3,4,12,kAudioServerPlugInIOOperationReadInput,2,&cycle,result,NULL)==noErr);
    assert(memcmp(source,result,sizeof(source))==0);
    // Feed shutdown clears queued voice even though Phone remains a reader.
    assert((*driver)->StopIO(driver,13,10)==noErr);
    assert((*driver)->DoIOOperation(driver,3,4,12,kAudioServerPlugInIOOperationReadInput,2,&cycle,result,NULL)==noErr);
    silent(result,4);
    assert((*driver)->StopIO(driver,13,10)!=noErr); // Wrong-side stop must not consume a reader.
    get(3,kAudioDevicePropertyDeviceIsRunning,global,&flag,sizeof(flag));assert(flag==1);
    get(13,kAudioDevicePropertyDeviceIsRunning,global,&flag,sizeof(flag));assert(flag==0);
    assert((*driver)->StartIO(driver,13,10)==noErr);
    assert((*driver)->GetZeroTimeStamp(driver,13,10,&sample2,&host2,&seed2)==noErr);assert(seed1==seed2);
    assert((*driver)->StopIO(driver,13,10)==noErr);
    assert((*driver)->StopIO(driver,3,12)==noErr);
}

int main(int argc,char **argv) {
    assert(argc==2);
    void *handle=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!handle){fprintf(stderr,"%s\n",dlerror());return 1;}
    void *(*create)(CFAllocatorRef,CFUUIDRef)=dlsym(handle,"NullAudio_Create");assert(create);
    driver=create(NULL,kAudioServerPlugInTypeUUID);assert(driver);
    AudioServerPlugInHostInterface host={0};host.CopyFromStorage=storage;host.PropertiesChanged=changed;
    assert((*driver)->Initialize(driver,&host)==noErr);
    check_split_devices();
    AudioObjectPropertyAddress address={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    CFStringRef name=NULL;UInt32 size=0;
    assert((*driver)->GetPropertyData(driver,3,0,&address,0,NULL,sizeof(name),&size,&name)==noErr);
    char text[128];CFStringGetCString(name,text,sizeof(text),kCFStringEncodingUTF8);assert(strcmp(text,"Phone Assistant")==0);printf("%s: ",text);
    Float64 rate=0;AudioValueRange range;UInt32 latency,period,flag;
    get(3,kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,&rate,sizeof(rate));assert(rate==48000);
    get(3,kAudioDevicePropertyAvailableNominalSampleRates,kAudioObjectPropertyScopeGlobal,&range,sizeof(range));assert(range.mMinimum==48000 && range.mMaximum==48000);
    get(3,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeInput,&latency,sizeof(latency));assert(latency==512);
    get(3,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeOutput,&flag,sizeof(flag));assert(flag==0);
    get(3,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput,&flag,sizeof(flag));assert(flag==0);
    get(3,kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,kAudioObjectPropertyScopeOutput,&flag,sizeof(flag));assert(flag==0);
    get(3,kAudioDevicePropertyZeroTimeStampPeriod,kAudioObjectPropertyScopeGlobal,&period,sizeof(period));assert(period==512);
    AudioStreamBasicDescription format;
    get(4,kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,&format,sizeof(format));
    assert(format.mSampleRate==48000 && format.mChannelsPerFrame==2 && format.mBytesPerFrame==8 && format.mBitsPerChannel==32 && format.mReserved==0);
    AudioStreamRangedDescription available;
    get(8,kAudioStreamPropertyAvailablePhysicalFormats,kAudioObjectPropertyScopeGlobal,&available,sizeof(available));
    assert(available.mSampleRateRange.mMinimum==48000 && available.mSampleRateRange.mMaximum==48000);
    rate=44100;assert(set(3,kAudioDevicePropertyNominalSampleRate,&rate,sizeof(rate))!=noErr);
    format.mSampleRate=44100;assert(set(4,kAudioStreamPropertyPhysicalFormat,&format,sizeof(format))!=noErr);
    assert((*driver)->PerformDeviceConfigurationChange(driver,3,44100,NULL)!=noErr);
    Boolean will,inplace;
    assert((*driver)->WillDoIOOperation(driver,3,1,kAudioServerPlugInIOOperationReadInput,&will,&inplace)==noErr && will && inplace);
    assert((*driver)->StartIO(driver,13,10)==noErr);
    assert((*driver)->StartIO(driver,3,1)==noErr);
    check_volume_contract();
    AudioServerPlugInIOCycleInfo cycle={0};float written[4]={0.25f,-0.5f,0.75f,-1},read[4]={0};
    cycle.mOutputTime.mFlags=kAudioTimeStampSampleTimeValid;
    cycle.mInputTime.mFlags=kAudioTimeStampSampleTimeValid;
    cycle.mOutputTime.mSampleTime=1024;
    assert((*driver)->DoIOOperation(driver,13,8,1,kAudioServerPlugInIOOperationWriteMix,2,&cycle,written,NULL)==noErr);
    cycle.mInputTime.mSampleTime=1536;
    assert((*driver)->DoIOOperation(driver,3,4,1,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);
    for(int i=0;i<4;i++)assert(read[i]==written[i]);
    assert((*driver)->StartIO(driver,3,2)==noErr);
    assert((*driver)->DoIOOperation(driver,3,4,2,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);
    assert(memcmp(read,written,sizeof(read))==0);
    // Reported decibels, scalar conversion and actual PCM amplitude agree.
    float db=-6.0206f,scalar=0;
    assert(set(5,kAudioLevelControlPropertyDecibelValue,&db,sizeof(db))==noErr);
    get(5,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,&scalar,sizeof(scalar));
    get(5,kAudioLevelControlPropertyDecibelValue,kAudioObjectPropertyScopeGlobal,&db,sizeof(db));assert(fabsf(db+6.0206f)<0.0001f);
    assert(scalar>0 && scalar<1);
    assert((*driver)->DoIOOperation(driver,3,4,2,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);
    for(int i=0;i<4;i++)assert(fabsf(read[i]-written[i]*0.5f)<0.00001f);
    db=NAN;assert(set(5,kAudioLevelControlPropertyDecibelValue,&db,sizeof(db))!=noErr);
    UInt32 mute=1;assert(set(6,kAudioBooleanControlPropertyValue,&mute,sizeof(mute))==noErr);
    assert((*driver)->DoIOOperation(driver,3,4,1,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);silent(read,4);
    mute=0;assert(set(6,kAudioBooleanControlPropertyValue,&mute,sizeof(mute))==noErr);
    db=0;assert(set(5,kAudioLevelControlPropertyDecibelValue,&db,sizeof(db))==noErr);
    // Each direction has a distinct, once-applied control.
    db=-6.0206f;assert(set(9,kAudioLevelControlPropertyDecibelValue,&db,sizeof(db))==noErr);
    cycle.mOutputTime.mSampleTime=2000;cycle.mInputTime.mSampleTime=2512;
    assert((*driver)->DoIOOperation(driver,13,8,1,kAudioServerPlugInIOOperationWriteMix,2,&cycle,written,NULL)==noErr);
    assert((*driver)->DoIOOperation(driver,3,4,2,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);
    for(int i=0;i<4;i++)assert(fabsf(read[i]-written[i]*0.5f)<0.00001f);
    db=0;assert(set(9,kAudioLevelControlPropertyDecibelValue,&db,sizeof(db))==noErr);
    cycle.mInputTime.mSampleTime=2514;
    assert((*driver)->DoIOOperation(driver,3,4,2,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);silent(read,4);
    Float64 sample1,sample2;UInt64 host1,host2,seed1,seed2;
    assert((*driver)->GetZeroTimeStamp(driver,3,1,&sample1,&host1,&seed1)==noErr);
    usleep(50000);
    assert((*driver)->GetZeroTimeStamp(driver,3,1,&sample2,&host2,&seed2)==noErr);
    assert(sample2-sample1>=2048 && seed1==seed2 && host2>=host1 && host2<=mach_absolute_time());
    struct mach_timebase_info tb;mach_timebase_info(&tb);
    double deltaSeconds=(double)(host2-host1)*tb.numer/tb.denom/1e9;
    assert(fabs(deltaSeconds-(sample2-sample1)/48000)<0.000001);
    // Deliberate malformed host invocation to exercise the driver's boundary.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    assert((*driver)->GetZeroTimeStamp(driver,3,1,NULL,&host1,&seed1)!=noErr);
#pragma clang diagnostic pop
    cycle.mInputTime.mSampleTime=NAN;
    assert((*driver)->DoIOOperation(driver,3,4,1,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)!=noErr);silent(read,4);
    cycle.mInputTime.mSampleTime=2512;
    assert((*driver)->DoIOOperation(driver,13,8,1,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)!=noErr);
    assert((*driver)->StopIO(driver,3,1)==noErr);
    // Stopping another reader does not flush remaining clients.
    assert((*driver)->DoIOOperation(driver,3,4,2,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);assert(read[0]!=0);
    assert((*driver)->StopIO(driver,3,2)==noErr);
    assert((*driver)->StopIO(driver,13,10)==noErr);
    assert((*driver)->StartIO(driver,13,10)==noErr);
    assert((*driver)->StartIO(driver,3,3)==noErr);
    assert((*driver)->GetZeroTimeStamp(driver,3,3,&sample2,&host2,&seed2)==noErr);assert(seed2!=seed1);
    assert((*driver)->DoIOOperation(driver,3,4,3,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);silent(read,4);
    cycle.mOutputTime.mSampleTime=2000;
    assert((*driver)->DoIOOperation(driver,13,8,3,kAudioServerPlugInIOOperationWriteMix,2,&cycle,written,NULL)==noErr);
    assert((*driver)->StopIO(driver,3,3)==noErr);
    assert((*driver)->StopIO(driver,13,10)==noErr);
    assert((*driver)->PerformDeviceConfigurationChange(driver,3,48000,NULL)==noErr);
    assert((*driver)->StartIO(driver,3,4)==noErr);
    assert((*driver)->DoIOOperation(driver,3,4,4,kAudioServerPlugInIOOperationReadInput,2,&cycle,read,NULL)==noErr);silent(read,4);
    assert((*driver)->StopIO(driver,3,4)==noErr);
    assert((*driver)->StopIO(driver,3,4)!=noErr);
    printf("HAL factory, split input/hidden feed, stable UID, ownership, shared clocks, feed shutdown, multiple readers, gain and lifecycle passed\n");
    // The production HAL owns plug-in lifetime; this isolated harness exits now.
    return 0;
}
