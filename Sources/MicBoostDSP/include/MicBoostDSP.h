#ifndef MICBOOST_DSP_H
#define MICBOOST_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>

/* Diagnostic capture only; no engine or DSP processing. */
typedef struct mb_capture mb_capture;

/* Preallocate interleaved Float32 storage; return NULL for invalid sizes or allocation failure. */
mb_capture * _Nullable mb_capture_create(size_t frames, unsigned channels);

uint64_t mb_capture_host_time(const mb_capture * _Nonnull capture);

/* Free capture storage after stopping and destroying its IOProc. */
void mb_capture_destroy(mb_capture * _Nonnull capture);

/* Read the number of captured frames with acquire ordering. */
size_t mb_capture_frames(const mb_capture * _Nonnull capture);

/* Borrow interleaved samples; read only after stopping the IOProc, before destroying capture. */
const float * _Nonnull mb_capture_samples(const mb_capture * _Nonnull capture);

/* Copy raw input into preallocated storage; context must point to a live mb_capture. */
OSStatus mb_capture_ioproc(
    AudioObjectID device,
    const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input,
    const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output,
    const AudioTimeStamp * _Nonnull outputTime,
    void * _Nullable context
);

typedef struct mb_engine mb_engine;
typedef enum {
    MB_AUTO,
    MB_MONO,
    MB_MONO_MIX,
    MB_STEREO,
} mb_channel_mode;
typedef enum {
    MB_LOW,
    MB_MID,
    MB_HIGH,
} mb_band;
typedef struct {
    uint32_t buffer, channel;
} mb_channel;
typedef struct {
    uint32_t input_count;
    mb_channel inputs[64];
    mb_channel outputs[2];
} mb_routing;
typedef struct {
    float input_peak, output_peak, gr_max_db;
    bool input_clipped, fade_done;
} mb_meters;
typedef struct {
    uint64_t cycles, input_missing, nonfinite_resets, frames_over_max, io_delta_host;
} mb_counters;
mb_engine * _Nullable mb_engine_create(uint32_t max_frames, double sample_rate);
void mb_engine_destroy(mb_engine * _Nonnull engine);
int mb_engine_configure(mb_engine * _Nonnull engine, const mb_routing * _Nonnull routing);
void mb_engine_set_gain_db(mb_engine * _Nonnull engine, float db);
typedef struct mb_monitor mb_monitor;
typedef struct {
    uint64_t latency_host, underruns, overruns_full, resets;
    uint32_t fill, target, max_pull, fill_min, fill_max;
    double correction;
    bool pulling;
} mb_monitor_stats;
typedef struct {
    double integral, filtered, correction, minimums[20];
    unsigned index, count;
} mb_monitor_pi;
double mb_monitor_pi_update(mb_monitor_pi * _Nonnull pi, double error, double rate,
                            double seconds);
mb_monitor * _Nullable mb_monitor_create(mb_engine * _Nonnull engine, double rate,
                                        uint32_t target);
void mb_monitor_destroy(mb_monitor * _Nonnull monitor);
void mb_engine_set_monitor_enabled(mb_engine * _Nonnull engine, bool enabled);
void mb_monitor_set_silent(mb_monitor * _Nonnull monitor, bool silent);
void mb_monitor_fade_out(mb_monitor * _Nonnull monitor);
void mb_monitor_read(mb_monitor * _Nonnull monitor, mb_monitor_stats * _Nonnull stats);
void mb_monitor_peek(const mb_monitor * _Nonnull monitor, mb_monitor_stats * _Nonnull stats);
void mb_monitor_set_target_base(mb_monitor * _Nonnull monitor, uint32_t engine_buffer,
                                uint32_t initial_pull);
void mb_monitor_write(mb_engine * _Nonnull engine, const float * _Nonnull left,
                      const float * _Nonnull right, uint32_t frames, uint64_t host);
OSStatus mb_monitor_render(void * _Nonnull context, AudioUnitRenderActionFlags * _Nonnull flags,
                          const AudioTimeStamp * _Nonnull timestamp, UInt32 bus,
                          UInt32 frames, AudioBufferList * _Nullable output);
void mb_engine_set_muted(mb_engine * _Nonnull engine, bool muted);
void mb_engine_set_eq_enabled(mb_engine * _Nonnull engine, bool enabled);
void mb_engine_set_band(mb_engine * _Nonnull engine, mb_band band, float hz, float db, float q);
void mb_engine_set_channel_mode(mb_engine * _Nonnull engine, mb_channel_mode mode, uint32_t first);
void mb_engine_begin_fade_out(mb_engine * _Nonnull engine);
void mb_engine_read_meters(mb_engine * _Nonnull engine, mb_meters * _Nonnull out);
void mb_engine_read_counters(const mb_engine * _Nonnull engine, mb_counters * _Nonnull out);
void mb_engine_process(mb_engine * _Nonnull engine,
    const float * _Nullable const * _Nonnull input,
    float * _Nullable const * _Nonnull output, uint32_t frames);
OSStatus mb_ioproc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull input_time,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull output_time,
    void * _Nullable context);
#endif
