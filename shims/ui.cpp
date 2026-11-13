/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Two Android 12 GraphicBufferMapper members, as free functions taking the object
 * first (the AArch64 member-call convention: `this` in x0, no sret for status_t).
 * Semantics kept: lock() still reports bytes per pixel/stride (A16's LockResult),
 * and A16's unlock(handle, nullptr) waits on the release fence and closes it,
 * which is what A12's unlock(handle) did.
 */

#include <ui/GraphicBufferMapper.h>
#include <ui/Rect.h>

using android::GraphicBufferMapper;
using android::OK;
using android::Rect;
using android::status_t;

namespace s666ln_shim {

status_t lock(GraphicBufferMapper* self, buffer_handle_t handle, uint32_t usage, const Rect& bounds,
              void** vaddr, int32_t* outBytesPerPixel, int32_t* outBytesPerStride)
        asm("_ZN7android19GraphicBufferMapper4lockEPK13native_handlejRKNS_4RectEPPvPiS9_");
status_t lock(GraphicBufferMapper* self, buffer_handle_t handle, uint32_t usage, const Rect& bounds,
              void** vaddr, int32_t* outBytesPerPixel, int32_t* outBytesPerStride) {
    auto result = self->lock(handle, static_cast<int64_t>(usage), bounds);
    if (!result.has_value()) return result.asStatus();
    auto val = result.value();
    *vaddr = val.address;
    if (outBytesPerPixel) *outBytesPerPixel = val.bytesPerPixel;
    if (outBytesPerStride) *outBytesPerStride = val.bytesPerStride;
    return OK;
}

status_t unlock(GraphicBufferMapper* self, buffer_handle_t handle)
        asm("_ZN7android19GraphicBufferMapper6unlockEPK13native_handle");
status_t unlock(GraphicBufferMapper* self, buffer_handle_t handle) {
    return self->unlock(handle, nullptr);
}

}  // namespace s666ln_shim
