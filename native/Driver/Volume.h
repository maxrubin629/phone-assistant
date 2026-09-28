// Original hardware-volume mapping shared by the HAL controls and PCM path.
#ifndef CODEX_CALL_VOLUME_H
#define CODEX_CALL_VOLUME_H
#include <math.h>

#define CALL_VOLUME_MIN_DB (-64.0f)
#define CALL_VOLUME_MAX_DB (0.0f)
// 10^(-64/20). Interpolate in amplitude, using s*s for a useful slider curve.
// Scalar zero is the finite -64 dB floor; mute is the separate exact-silence
// control. Scalar one is exactly unity. Both directions use this same mapping.
static const double callVolumeFloorGain = 0.0006309573444801932;

static float call_volume_scalar_to_gain(float scalar) {
    if (!isfinite(scalar)) return 0; // Fail silent in the realtime path.
    if (scalar <= 0) return (float)callVolumeFloorGain;
    if (scalar >= 1) return 1;
    double position = (double)scalar * (double)scalar;
    return (float)(callVolumeFloorGain + (1.0-callVolumeFloorGain)*position);
}

static float call_volume_scalar_to_db(float scalar) {
    if (!isfinite(scalar)) return NAN;
    if (scalar <= 0) return CALL_VOLUME_MIN_DB;
    if (scalar >= 1) return CALL_VOLUME_MAX_DB;
    double position = (double)scalar * (double)scalar;
    return (float)(20.0*log10(callVolumeFloorGain + (1.0-callVolumeFloorGain)*position));
}

static float call_volume_db_to_scalar(float decibels) {
    if (!isfinite(decibels)) return NAN;
    if (decibels <= CALL_VOLUME_MIN_DB) return 0;
    if (decibels >= CALL_VOLUME_MAX_DB) return 1;
    double gain = pow(10.0, (double)decibels/20.0);
    return (float)sqrt(fmax(0.0, fmin(1.0, (gain-callVolumeFloorGain)/(1.0-callVolumeFloorGain))));
}
#endif
