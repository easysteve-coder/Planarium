#include "PlanariumFadeDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

struct PlanariumFadeState {
    _Atomic(uint32_t) command;
    _Atomic(uint32_t) reached;
    uint32_t serial; // sole control-thread writer
    uint32_t observed; // remaining fields: sole render-thread writer
    uint32_t duration, remaining;
    float current, target, step;
};
PlanariumFadeState *planarium_fade_create(void) {
    PlanariumFadeState *s = calloc(1, sizeof(*s));
    if (s) {
        atomic_init(&s->command, 0);
        atomic_init(&s->reached, 0);
        planarium_fade_reset(s, 48000, 0);
    }
    return s;
}
void planarium_fade_destroy(PlanariumFadeState *s) { free(s); }
int planarium_fade_lock_free(PlanariumFadeState *s) {
    return atomic_is_lock_free(&s->command) && atomic_is_lock_free(&s->reached);
}
uint32_t planarium_fade_request(PlanariumFadeState *s, int silent) {
    uint32_t old = atomic_load_explicit(&s->command, memory_order_acquire);
    if ((old & 1u) == !!silent) return old;
    s->serial = (s->serial + 2u) & ~1u;
    uint32_t next = s->serial | !!silent;
    atomic_store_explicit(&s->command, next, memory_order_release);
    return next;
}
void planarium_fade_reset(PlanariumFadeState *s, double rate, int silent) {
    uint32_t token = planarium_fade_request(s, silent);
    s->duration = (uint32_t)fmax(1, round(rate * 0.010));
    s->remaining = 0;
    s->observed = token;
    s->current = s->target = silent ? 0 : 1;
    s->step = 0;
    atomic_store_explicit(&s->reached, token, memory_order_release);
}
int planarium_fade_reached(PlanariumFadeState *s, uint32_t token) {
    return atomic_load_explicit(&s->reached, memory_order_acquire) == token;
}
void planarium_fade_render(PlanariumFadeState *s, AudioBufferList *buffers, uint32_t frames) {
    uint32_t command = atomic_load_explicit(&s->command, memory_order_acquire);
    if (s->observed != command) {
        s->observed = command;
        s->target = (command & 1u) ? 0 : 1;
        s->remaining = s->duration;
        s->step = (s->target - s->current) / s->duration;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        if (s->remaining) {
            s->current += s->step;
            if (--s->remaining == 0) {
                s->current = s->target;
                atomic_store_explicit(&s->reached, command, memory_order_release);
            }
        }
        for (uint32_t buffer = 0; buffer < buffers->mNumberBuffers; ++buffer) {
            AudioBuffer *b = &buffers->mBuffers[buffer];
            float *samples = b->mData;
            if (!samples) continue;
            for (uint32_t ch = 0; ch < b->mNumberChannels; ++ch)
                samples[frame * b->mNumberChannels + ch] *= s->current;
        }
    }
}
