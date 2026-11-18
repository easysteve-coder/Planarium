#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

typedef struct PlanariumHostClockStorage PlanariumHostClockStorage;
typedef struct {
    double tempo, beat, seconds, previousTempo;
    uint64_t generation, transport;
    int moving;
} PlanariumHostClockSnapshot;
// Creation, destruction and publication are control-side only. One serialized
// writer; render readers use atomic fields and a bounded coherent read.
PlanariumHostClockStorage * _Nullable planarium_host_clock_create(void);
void planarium_host_clock_destroy(PlanariumHostClockStorage * _Nonnull clock);
void planarium_host_clock_publish(PlanariumHostClockStorage * _Nonnull clock, PlanariumHostClockSnapshot value);
int planarium_host_clock_lock_free(PlanariumHostClockStorage * _Nonnull clock);
// Engine stopped: start a new sample-time epoch shared by every AU/branch.
void planarium_host_clock_reset_render_epoch(PlanariumHostClockStorage * _Nonnull clock);

NS_ASSUME_NONNULL_BEGIN
// Instance and graph own this binding. The native node owner must outlive
// callback cleanup: retaining an AUv2 bridge alone does not retain its handle.
// Blocks capture only a C pointer. No ObjC messaging or Swift capture on render.
@interface PlanariumHostClockBinding : NSObject
- (nullable instancetype)initWithUnit:(AUAudioUnit *)unit owner:(NSObject *)owner clock:(PlanariumHostClockStorage *)clock
                  sampleRate:(double)sampleRate offline:(BOOL)offline;
// Only after rendering has been deallocated: keep the SAME callback storage
// across graph rebuilds, including AUs that cache host blocks for their lifetime.
- (void)configureWithClock:(PlanariumHostClockStorage *)clock sampleRate:(double)sampleRate offline:(BOOL)offline;
@end
NS_ASSUME_NONNULL_END

// One preallocated observer mailbox per instrument. Atomic fields make reads
// coherent without a render lock; an incoherent/unknown anchor is invalid.
typedef struct { double seconds, sample, rate; uint32_t frames; int valid; } PlanariumNoteRenderAnchor;
NS_ASSUME_NONNULL_BEGIN
@interface PlanariumNoteRenderBinding : NSObject
- (nullable instancetype)initWithUnit:(AUAudioUnit *)unit owner:(NSObject *)owner;
- (PlanariumNoteRenderAnchor)readAnchor;
- (void)configureSampleRate:(double)rate;
@end
NS_ASSUME_NONNULL_END

// Q is the sole producer; the instrument's existing observer is the sole reader.
// Lifetime follows PlanariumNoteRenderBinding, including graph retirement.
typedef struct PlanariumNoteRing PlanariumNoteRing;
typedef struct { double sample; uint64_t generation; uint8_t status, note, velocity; uint64_t voice; } PlanariumSampleNote;
PlanariumNoteRing * _Nullable planarium_note_ring_create(void);
void planarium_note_ring_destroy(PlanariumNoteRing * _Nonnull ring);
uint64_t planarium_note_ring_invalidate(PlanariumNoteRing * _Nonnull ring);
uint64_t planarium_note_ring_generation(PlanariumNoteRing * _Nonnull ring);
int planarium_note_ring_push(PlanariumNoteRing * _Nonnull ring, PlanariumSampleNote note);
void planarium_note_ring_render(PlanariumNoteRing * _Nonnull ring, double sample, uint32_t frames,
                               AUScheduleMIDIEventBlock __unsafe_unretained _Nonnull midi);
NS_ASSUME_NONNULL_BEGIN
@interface PlanariumNoteRenderBinding (SampleNotes)
- (PlanariumNoteRing *)sampleNotes;
@end
NS_ASSUME_NONNULL_END
