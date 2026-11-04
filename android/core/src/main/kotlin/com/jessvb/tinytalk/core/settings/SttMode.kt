package com.jessvb.tinytalk.core.settings

enum class SttMode { ON_DEVICE, CLOUD }

interface SttModeStore {
    var mode: SttMode
}
