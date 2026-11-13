/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Android 12 declared SetTaskProfiles inside __BEGIN_DECLS, so its symbol is the
 * plain C name; Android 16 keeps the same vector<string> overload, mangled.
 */

#include <string>
#include <vector>

#include <processgroup/processgroup.h>

namespace s666ln_shim {

bool SetTaskProfiles(int tid, const std::vector<std::string>& profiles, bool use_fd_cache)
        asm("SetTaskProfiles");
bool SetTaskProfiles(int tid, const std::vector<std::string>& profiles, bool use_fd_cache) {
    return ::SetTaskProfiles(tid, profiles, use_fd_cache);
}

}  // namespace s666ln_shim
