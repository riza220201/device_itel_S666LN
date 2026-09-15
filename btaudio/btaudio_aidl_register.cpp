/*
 * libbtaudioaidlreg - register AOSP's AIDL IBluetoothAudioProviderFactory
 * from inside the MediaTek audio HAL process.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (C) 2026 The LineageOS Project
 *
 * WHY THIS EXISTS
 *   The One UI 8 port runs Samsung's A16 Bluetooth stack against this device's
 *   A13 vendor. Measured 2026-09-15 on hardware:
 *
 *     BT stack (apex, Samsung A16)  AIDL client ONLY. Its AOSP HIDL bluetooth
 *                                   audio descriptors number ZERO, against 18
 *                                   for its own vendor.samsung.hardware.
 *                                   bluetooth.audio@2.x (the control). So the
 *                                   six HIDL providers our vendor registers
 *                                   have no possible client -- lshal shows them
 *                                   at 0 clients, and that is why.
 *     our vendor                    audio.bluetooth.default.so already carries
 *                                   BOTH BTAudioHalDeviceProxyAIDL and
 *                                   ...HIDL, already links
 *                                   android.hardware.bluetooth.audio-V2-ndk,
 *                                   and picks between them with
 *                                   BluetoothAudioSession::IsAidlAvailable().
 *
 *   So the only missing piece is the AIDL provider itself. Without it:
 *     BTAudioA2dpAIDL: init: BluetoothAudio AIDL implementation does not exist
 *     -> btif_a2dp_source_startup: Failed to setup the bluetooth audio HAL
 *     -> BTAudioHalDeviceProxyHIDL: A2DP_SOFTWARE_ENCODING_DATAPATH is not ready
 *     -> adev_open_output_stream: cannot init HAL -> media stays on the speaker.
 *
 * 🔴 WHY IT CANNOT BE A STANDALONE SERVICE, WHICH IS THE OBVIOUS DESIGN
 *   BluetoothAudioSessionInstance::sessions_map_ is a process-local `static`.
 *   The provider WRITES it (BluetoothAudioSessionReport::OnSessionStarted) and
 *   audio.bluetooth.default.so READS it (IsSessionReady), through the same
 *   libbluetooth_audio_session_aidl. A provider in its own process would leave
 *   the audio HAL's session permanently "not ready" -- the exact symptom we are
 *   trying to fix. AOSP agrees by construction: its provider ships as a
 *   cc_library_shared whose entry point the AUDIO HAL SERVICE dlopens
 *   (hardware/interfaces/audio/common/all-versions/default/service/service.cpp,
 *   optionalInterfaceSharedLibs), never as a cc_binary.
 *
 * 🔴 AND THE LOADER IS MISSING HERE
 *   /vendor/bin/hw/android.hardware.audio.service.mediatek is a PROPRIETARY
 *   PREBUILT and contains "createIBluetoothAudioProviderFactory" ZERO times
 *   (control: "IDevicesFactory" twice). MediaTek forked AOSP's audio service
 *   before that loop existed, so nothing on this device will ever call it.
 *   This library supplies the call, and reaches the right process by being an
 *   injected DT_NEEDED of a library the audio HAL already dlopens at startup.
 *
 * ⚠ WHY A DETACHED THREAD RATHER THAN THE CONSTRUCTOR ITSELF
 *   The constructor runs under the dynamic loader lock, inside dlopen(). Doing
 *   binder I/O there risks a loader deadlock if anything downstream dlopens.
 *   The registration is handed to a detached thread so dlopen always returns.
 *   Ordering is safe: the audio HAL is started long before the Bluetooth stack
 *   asks, and the client blocks in waitForService if it somehow asks first.
 *
 * ⚠ VERSION GAP, STATED BECAUSE IT IS NOT PROVEN
 *   Samsung's client is built against android.hardware.bluetooth.audio-V5-ndk;
 *   this tree carries V2. Stable AIDL is append-only, so transactions 1 and 2
 *   (getProviderCapabilities, openProvider) are identical in both -- but a V5
 *   client against a V2 server is a prediction until it is measured.
 */

#include <pthread.h>

#include <android/binder_process.h>
#include <android/binder_status.h>
#include <log/log.h>

/*
 * Defined by android.hardware.bluetooth.audio-impl (AOSP, unmodified):
 * hardware/interfaces/bluetooth/audio/aidl/default/service.cpp. It constructs
 * the factory and calls AServiceManager_addService() with
 * "android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default".
 *
 * That name already resolves to u:object_r:hal_audio_service:s0 in Samsung's
 * own /system/etc/selinux/plat_service_contexts (line 38, measured), so no
 * service_contexts edit is required on this port.
 */
extern "C" binder_status_t createIBluetoothAudioProviderFactory();

static void* rs4_btaudio_register(void*) {
    /*
     * The audio HAL is primarily a HIDL server and joins the hwbinder pool. An
     * AIDL service additionally needs a /dev/binder thread pool. Starting one
     * is additive -- measured: the process already holds an open fd on
     * /dev/binderfs/binder, so the domain is permitted to use it.
     */
    ABinderProcess_setThreadPoolMaxThreadCount(1);
    ABinderProcess_startThreadPool();

    binder_status_t status = createIBluetoothAudioProviderFactory();
    if (status == STATUS_OK) {
        ALOGI("rs4-btaudioaidl: IBluetoothAudioProviderFactory registered");
    } else {
        /* Loud on failure: a silent miss here looks exactly like the bug. */
        ALOGE("rs4-btaudioaidl: registration FAILED, status=%d", status);
    }
    return nullptr;
}

__attribute__((constructor)) static void rs4_btaudio_aidl_init(void) {
    pthread_t thread;
    int rc = pthread_create(&thread, nullptr, rs4_btaudio_register, nullptr);
    if (rc != 0) {
        ALOGE("rs4-btaudioaidl: pthread_create failed, rc=%d", rc);
        return;
    }
    pthread_detach(thread);
}
