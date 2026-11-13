/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Android 12 libbase signatures (prebuilts/vndk/v31 include: strings.h:36,
 * file.h:87, file.h:121) forwarded to the Android 16 string_view versions.
 */

#include <string>
#include <string_view>

#include <android-base/file.h>
#include <android-base/strings.h>
#include <android-base/unique_fd.h>

using android::base::borrowed_fd;

namespace s666ln_shim {

std::string Trim(const std::string& s)
        asm("_ZN7android4base4TrimERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE");
std::string Trim(const std::string& s) {
    return android::base::Trim(std::string_view(s));
}

std::string Basename(const std::string& path)
        asm("_ZN7android4base8BasenameERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE");
std::string Basename(const std::string& path) {
    return android::base::Basename(std::string_view(path));
}

bool WriteStringToFd(const std::string& content, borrowed_fd fd)
        asm("_ZN7android4base15WriteStringToFdERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEENS0_11borrowed_fdE");
bool WriteStringToFd(const std::string& content, borrowed_fd fd) {
    return android::base::WriteStringToFd(std::string_view(content), fd);
}

}  // namespace s666ln_shim
