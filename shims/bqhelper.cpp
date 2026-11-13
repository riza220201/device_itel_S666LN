/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Android 16 renamed GraphicBufferSource::getHGraphicBufferProducer() to
 * getHGraphicBufferProducer_V1_0(), same return type
 * (sp<bufferqueue::V1_0::IGraphicBufferProducer>).
 *
 * The real GraphicBufferSource.h pulls in libgui's static flags, media foundation
 * and binder headers. Only the one non-virtual member is called here, and a
 * member function's mangled name does not depend on the class body, so the class
 * is declared with that member alone; no object layout is touched.
 * AArch64: `this` in x0 and the sret pointer in x8, for the member function and
 * for this free function alike.
 */

#include <android/hardware/graphics/bufferqueue/1.0/IGraphicBufferProducer.h>
#include <utils/StrongPointer.h>

using HGraphicBufferProducerV1_0 = ::android::hardware::graphics::bufferqueue::V1_0::IGraphicBufferProducer;

namespace android {
class GraphicBufferSource {
  public:
    sp<HGraphicBufferProducerV1_0> getHGraphicBufferProducer_V1_0() const;
};
}  // namespace android

namespace s666ln_shim {

android::sp<HGraphicBufferProducerV1_0> getHGraphicBufferProducer(
        const android::GraphicBufferSource* self)
        asm("_ZNK7android19GraphicBufferSource25getHGraphicBufferProducerEv");
android::sp<HGraphicBufferProducerV1_0> getHGraphicBufferProducer(
        const android::GraphicBufferSource* self) {
    return self->getHGraphicBufferProducer_V1_0();
}

}  // namespace s666ln_shim
