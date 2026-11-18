#import "PlanariumHostClockDSP.h"
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
#include <math.h>
#include <mach/mach_time.h>

struct PlanariumHostClockStorage {
    _Atomic uint32_t owners;
    _Atomic uint64_t sequence;
    _Atomic double tempo, beat, seconds, previousTempo;
    _Atomic uint64_t generation, transport;
    _Atomic int moving;
    _Atomic double renderEpoch;
};
PlanariumHostClockStorage *planarium_host_clock_create(void) {
    PlanariumHostClockStorage *c = calloc(1, sizeof(*c));
    if (c) { atomic_init(&c->sequence, 0); atomic_init(&c->tempo, 120);
        atomic_init(&c->owners, 1);
        atomic_init(&c->beat, 0); atomic_init(&c->seconds, 0);
        atomic_init(&c->previousTempo, 120);
        atomic_init(&c->generation, 0); atomic_init(&c->transport, 0); atomic_init(&c->moving, 0); }
    if (c) atomic_init(&c->renderEpoch, NAN);
    return c;
}
void planarium_host_clock_destroy(PlanariumHostClockStorage *c) {
    // Ownership changes ONLY during construction/teardown, never in a block.
    if (atomic_fetch_sub(&c->owners, 1) == 1) free(c);
}
int planarium_host_clock_lock_free(PlanariumHostClockStorage *c) {
    return atomic_is_lock_free(&c->owners) && atomic_is_lock_free(&c->sequence) && atomic_is_lock_free(&c->tempo) &&
        atomic_is_lock_free(&c->beat) && atomic_is_lock_free(&c->seconds) && atomic_is_lock_free(&c->previousTempo) &&
        atomic_is_lock_free(&c->generation) && atomic_is_lock_free(&c->transport) && atomic_is_lock_free(&c->moving) && atomic_is_lock_free(&c->renderEpoch);
}
void planarium_host_clock_reset_render_epoch(PlanariumHostClockStorage *c) { atomic_store(&c->renderEpoch, NAN); }
// seq_cst for ALL fields makes the seqlock proof portable and TSan-clean:
// equal even sequences imply no interleaved publication in the total order.
void planarium_host_clock_publish(PlanariumHostClockStorage *c, PlanariumHostClockSnapshot s) {
    atomic_fetch_add(&c->sequence, 1);
    atomic_store(&c->tempo, s.tempo); atomic_store(&c->beat, s.beat); atomic_store(&c->seconds, s.seconds);
    atomic_store(&c->previousTempo, s.previousTempo);
    atomic_store(&c->generation, s.generation); atomic_store(&c->transport, s.transport); atomic_store(&c->moving, s.moving);
    atomic_fetch_add(&c->sequence, 1);
}
static int read_clock(PlanariumHostClockStorage *c, PlanariumHostClockSnapshot *result) {
    for (int i = 0; i < 3; ++i) {
        uint64_t before = atomic_load(&c->sequence);
        if (before & 1) continue;
        PlanariumHostClockSnapshot s = {atomic_load(&c->tempo), atomic_load(&c->beat), atomic_load(&c->seconds),
            atomic_load(&c->previousTempo),
            atomic_load(&c->generation), atomic_load(&c->transport), atomic_load(&c->moving)};
        if (before == atomic_load(&c->sequence)) { *result = s; return 1; }
    }
    return 0; // use this AU's previous coherent buffer; never spin on a writer
}
typedef struct {
    PlanariumHostClockStorage *clock;
    PlanariumHostClockSnapshot snapshot;
    double rate, hostScale, epoch, sample, beat, tempo;
    uint64_t observedTransport;
    int offline, pendingStart;
} RenderContext;
static void begin_render(RenderContext *r, const AudioTimeStamp *t) {
    read_clock(r->clock, &r->snapshot);
    double sample = t->mSampleTime;
    // Sample time is the render timeline. Host time ONLY aligns its epoch;
    // no current-time read or wall-time accumulation occurs on the render path.
    if (!r->offline && (t->mFlags & kAudioTimeStampHostTimeValid))
        r->epoch = (double)t->mHostTime * r->hostScale - sample / r->rate;
    else {
        double epoch = atomic_load(&r->clock->renderEpoch);
        if (isnan(epoch)) {
            double desired = r->snapshot.seconds - sample / r->rate;
            // A single CAS, not a retry/spin; every AU uses the winner's epoch.
            if (atomic_compare_exchange_strong(&r->clock->renderEpoch, &epoch, desired)) epoch = desired;
        }
        r->epoch = epoch;
    }
    r->sample = sample;
    double elapsed = r->epoch + sample / r->rate - r->snapshot.seconds;
    r->pendingStart = r->snapshot.moving && elapsed < 0 && r->snapshot.beat == 0;
    double tempo = elapsed < 0 ? r->snapshot.previousTempo : r->snapshot.tempo;
    r->beat = fmax(0, r->snapshot.beat + (r->snapshot.moving ? elapsed * tempo / 60 : 0));
    r->tempo = tempo;
}
static NSInteger next_beat(RenderContext *r) {
    return (NSInteger)ceil((ceil(r->beat) - r->beat) * 60 / r->tempo * r->rate);
}
@implementation PlanariumHostClockBinding {
    AUAudioUnit *_unit;
    NSObject *_owner;
    NSInteger _token;
    BOOL _installed;
    RenderContext *_context;
}
- (instancetype)initWithUnit:(AUAudioUnit *)unit owner:(NSObject *)owner clock:(PlanariumHostClockStorage *)clock
                  sampleRate:(double)sampleRate offline:(BOOL)offline {
    if ((self = [super init])) {
        _unit = unit;
        _owner = owner;
        _context = calloc(1, sizeof(*_context));
        if (!_context) return nil;
        RenderContext *r = _context;
        atomic_fetch_add(&clock->owners, 1);
        r->clock = clock; r->rate = sampleRate; r->offline = offline;
        r->snapshot.tempo = 120; read_clock(clock, &r->snapshot);
        r->tempo = r->snapshot.tempo;
        // A new AU starts with no observed moving transport. This also keeps
        // a future Start visible when the AU binds during the 50 ms lead-in.
        r->observedTransport = r->snapshot.transport - (r->snapshot.moving ? 1 : 0);
        mach_timebase_info_data_t info; mach_timebase_info(&info);
        r->hostScale = (double)info.numer / info.denom / 1e9;
        [self installCallbacks];
    }
    return self;
}
- (void)installCallbacks {
        RenderContext *r = _context;
        AUAudioUnit *unit = _unit;
        if (_installed) [unit removeRenderObserver:_token];
        unit.musicalContextBlock = ^BOOL(double *tempo, double *numerator, NSInteger *denominator,
                                         double *beat, NSInteger *offset, double *downbeat) {
            if (tempo) *tempo = r->tempo;
            if (numerator) *numerator = 4;
            if (denominator) *denominator = 4;
            if (beat) *beat = r->beat;
            if (offset) *offset = next_beat(r);
            if (downbeat) *downbeat = floor(r->beat / 4) * 4;
            return YES;
        };
        unit.transportStateBlock = ^BOOL(AUHostTransportStateFlags *flags, double *sample, double *start, double *end) {
            AUHostTransportStateFlags value = r->snapshot.moving && !r->pendingStart ? AUHostTransportStateMoving : 0;
            if (!r->pendingStart && r->observedTransport != r->snapshot.transport) value |= AUHostTransportStateChanged;
            if (flags) { *flags = value; if (!r->pendingStart) r->observedTransport = r->snapshot.transport; }
            if (sample) *sample = r->sample;
            if (start) *start = 0;
            if (end) *end = 0;
            return YES;
        };
        _token = [unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags, const AudioTimeStamp *time,
                                                    AUAudioFrameCount count, NSInteger bus) {
            if (flags & kAudioUnitRenderAction_PreRender) begin_render(r, time);
        }];
        _installed = YES;
}
- (void)configureWithClock:(PlanariumHostClockStorage *)clock sampleRate:(double)sampleRate offline:(BOOL)offline {
    RenderContext *r = _context;
    if (r->clock != clock) {
        atomic_fetch_add(&clock->owners, 1);
        PlanariumHostClockStorage *old = r->clock;
        r->clock = clock;
        planarium_host_clock_destroy(old);
    }
    r->rate = sampleRate; r->offline = offline;
    [self installCallbacks];
}
- (void)dealloc {
    if (_installed) [_unit removeRenderObserver:_token];
    _unit.musicalContextBlock = nil; _unit.transportStateBlock = nil;
    _unit = nil;
    if (_context) planarium_host_clock_destroy(_context->clock);
    free(_context);
    _owner = nil;
}
@end

struct PlanariumNoteRing {
    _Atomic uint32_t head, tail, retired;
    _Atomic uint64_t generation;
    uint64_t observed;
    PlanariumSampleNote events[256];
    PlanariumSampleNote pending[256];
    uint32_t pendingCount;
    uint64_t sounding[16 * 128];
};
PlanariumNoteRing *planarium_note_ring_create(void) {
    PlanariumNoteRing *r = calloc(1, sizeof(*r));
    if (r) { atomic_init(&r->head, 0); atomic_init(&r->tail, 0); atomic_init(&r->retired, 0); atomic_init(&r->generation, 1); r->observed = 1; }
    return r;
}
void planarium_note_ring_destroy(PlanariumNoteRing *r) { free(r); }
uint64_t planarium_note_ring_generation(PlanariumNoteRing *r) { return atomic_load_explicit(&r->generation, memory_order_acquire); }
uint64_t planarium_note_ring_invalidate(PlanariumNoteRing *r) {
    return atomic_fetch_add_explicit(&r->generation, 1, memory_order_acq_rel) + 1;
}
int planarium_note_ring_push(PlanariumNoteRing *r, PlanariumSampleNote n) {
    uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (head - tail == 256 || head - atomic_load_explicit(&r->retired, memory_order_acquire) >= 256 || !n.voice || !isfinite(n.sample) || n.note > 127 || n.velocity > 127 ||
        ((n.status & 0xf0) != 0x90 && (n.status & 0xf0) != 0x80) ||
        n.generation != planarium_note_ring_generation(r)) return 0;
    r->events[head % 256] = n;
    atomic_store_explicit(&r->head, head + 1, memory_order_release);
    return 1;
}
static void note_ring_release(PlanariumNoteRing *r, AUScheduleMIDIEventBlock __unsafe_unretained midi) {
    for (int k = 0; k < 16 * 128; ++k) if (r->sounding[k]) {
        uint8_t bytes[3] = {0x80 | (k / 128), k % 128, 0};
        midi(AUEventSampleTimeImmediate, 0, 3, bytes);
        r->sounding[k] = 0;
    }
}
static int sample_note_on(PlanariumSampleNote n) { return (n.status & 0xf0) == 0x90 && n.velocity > 0; }
static int sample_note_before(PlanariumSampleNote a, PlanariumSampleNote b) {
    return a.sample < b.sample || (a.sample == b.sample && !sample_note_on(a) && sample_note_on(b));
}
static void sample_note_retire(PlanariumNoteRing *r) {
    // Only render writes retired, only Q writes head. No contested RMW is
    // required to bound transport + future calendar to one 256-event budget.
    uint32_t retired = atomic_load_explicit(&r->retired, memory_order_relaxed);
    atomic_store_explicit(&r->retired, retired + 1, memory_order_release);
}
static void sample_note_remove(PlanariumNoteRing *r, uint32_t index) {
    for (uint32_t j = index + 1; j < r->pendingCount; ++j) r->pending[j - 1] = r->pending[j];
    --r->pendingCount;
    sample_note_retire(r);
}
void planarium_note_ring_render(PlanariumNoteRing *r, double sample, uint32_t frames, AUScheduleMIDIEventBlock __unsafe_unretained midi) {
    if (!isfinite(sample) || !frames) return;
    uint64_t generation = planarium_note_ring_generation(r);
    if (generation != r->observed) { note_ring_release(r, midi); r->observed = generation; }
    for (uint32_t i = 0; i < r->pendingCount;) {
        if (r->pending[i].generation != generation) sample_note_remove(r, i); else ++i;
    }
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    // Future gate Offs must not block an earlier On after a tempo change.
    // Both arrays are allocated at construction; head - retired bounds TOTAL
    // admission to 256, including events already moved off the SPSC transport.
    for (uint32_t i = 0; tail != head && i < 256; ++i) {
        if (planarium_note_ring_generation(r) != generation) break;
        PlanariumSampleNote n = r->events[tail % 256];
        ++tail; atomic_store_explicit(&r->tail, tail, memory_order_release);
        if (n.generation != generation) {
            sample_note_retire(r);
            continue;
        }
        uint32_t insert = r->pendingCount;
        while (insert > 0 && sample_note_before(n, r->pending[insert - 1])) {
            r->pending[insert] = r->pending[insert - 1]; --insert;
        }
        r->pending[insert] = n; ++r->pendingCount;
    }
    for (uint32_t i = 0; r->pendingCount && i < 256; ++i) {
        // Never release at offset zero midway through a quantum: an On
        // already handed over at a later offset could otherwise outlive it.
        if (planarium_note_ring_generation(r) != generation) break;
        PlanariumSampleNote n = r->pending[0];
        if (n.sample >= sample + frames) break;
        int key = (n.status & 15) * 128 + n.note;
        AUEventSampleTime offset = (AUEventSampleTime)fmax(0, n.sample - sample);
        uint8_t bytes[3] = {n.status, n.note, n.velocity};
        if (sample_note_on(n)) {
            if (r->sounding[key]) {
                uint8_t off[3] = {0x80 | (n.status & 15), n.note, 0};
                r->sounding[key] = 0;
                midi(AUEventSampleTimeImmediate + offset, 0, 3, off);
                if (planarium_note_ring_generation(r) != generation) break;
            }
            r->sounding[key] = n.voice; // synchronous receipt BEFORE handover
            midi(AUEventSampleTimeImmediate + offset, 0, 3, bytes);
        } else if (r->sounding[key] == n.voice) {
            r->sounding[key] = 0;
            midi(AUEventSampleTimeImmediate + offset, 0, 3, bytes);
        }
        // An old gate Off cannot cut a retriggered newer voice of the same key.
        sample_note_remove(r, 0);
    }
}

typedef struct {
    _Atomic uint64_t sequence;
    _Atomic double seconds, sample, rate, configuredRate;
    _Atomic uint32_t frames;
    _Atomic int valid;
    double scale;
} NoteRenderStorage;
@implementation PlanariumNoteRenderBinding {
    AUAudioUnit *_noteUnit;
    NSObject *_noteOwner;
    NSInteger _noteToken;
    NoteRenderStorage *_noteStorage;
    PlanariumNoteRing *_sampleNotes;
}
- (instancetype)initWithUnit:(AUAudioUnit *)unit owner:(NSObject *)owner {
    if ((self = [super init])) {
        _noteUnit = unit; _noteOwner = owner;
        _sampleNotes = planarium_note_ring_create();
        if (!_sampleNotes) return nil;
        _noteStorage = calloc(1, sizeof(*_noteStorage));
        if (!_noteStorage) return nil;
        NoteRenderStorage *s = _noteStorage;
        atomic_init(&s->sequence, 0); atomic_init(&s->seconds, 0);
        atomic_init(&s->sample, 0); atomic_init(&s->rate, 0); atomic_init(&s->frames, 0); atomic_init(&s->valid, 0);
        mach_timebase_info_data_t info; mach_timebase_info(&info);
        s->scale = (double)info.numer / info.denom / 1e9;
        atomic_init(&s->configuredRate, 0);
        // The native format is captured outside render. configureSampleRate
        // refreshes it before a binding is reused after a format change.
        atomic_store(&s->configuredRate, unit.outputBusses.count > 0 ? [unit.outputBusses objectAtIndexedSubscript:0].format.sampleRate : 0);
        PlanariumNoteRing *ring = _sampleNotes;
        AUScheduleMIDIEventBlock midi = unit.scheduleMIDIEventBlock;
        _noteToken = [unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,
            const AudioTimeStamp *time, AUAudioFrameCount count, NSInteger bus) {
            if (!(flags & kAudioUnitRenderAction_PreRender) || bus != 0) return;
            atomic_fetch_add(&s->sequence, 1);
            int valid = (time->mFlags & kAudioTimeStampHostTimeValid) && (time->mFlags & kAudioTimeStampSampleTimeValid);
            atomic_store(&s->seconds, (double)time->mHostTime * s->scale);
            atomic_store(&s->sample, (time->mFlags & kAudioTimeStampSampleTimeValid) ? time->mSampleTime : NAN);
            atomic_store(&s->rate, atomic_load(&s->configuredRate));
            atomic_store(&s->frames, count);
            atomic_store(&s->valid, valid);
            atomic_fetch_add(&s->sequence, 1);
            if (midi && (time->mFlags & kAudioTimeStampSampleTimeValid))
                planarium_note_ring_render(ring, time->mSampleTime, count, midi);
        }];
    }
    return self;
}
- (PlanariumNoteRing *)sampleNotes { return _sampleNotes; }
- (void)configureSampleRate:(double)rate {
    atomic_store(&_noteStorage->configuredRate, rate);
    atomic_store(&_noteStorage->frames, 0);
}
- (PlanariumNoteRenderAnchor)readAnchor {
    NoteRenderStorage *s = _noteStorage;
    for (int i = 0; i < 3; ++i) {
        uint64_t before = atomic_load(&s->sequence);
        if (before & 1) continue;
        PlanariumNoteRenderAnchor a = {atomic_load(&s->seconds), atomic_load(&s->sample),
            atomic_load(&s->rate), atomic_load(&s->frames), atomic_load(&s->valid)};
        if (before == atomic_load(&s->sequence)) { a.valid = a.valid && a.frames > 0 && a.rate > 0; return a; }
    }
    return (PlanariumNoteRenderAnchor){0};
}
- (void)dealloc {
    if (_noteStorage) { [_noteUnit removeRenderObserver:_noteToken]; free(_noteStorage); }
    planarium_note_ring_destroy(_sampleNotes);
    _noteUnit = nil; _noteOwner = nil;
}
@end
