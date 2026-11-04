package com.jessvb.tinytalk.keys

/** Which key a service uses, for the Settings status line. Never exposes the key itself. */
enum class KeyStatus(val label: String) {
    YOURS("Using your key"),
    BUILT_IN("Using the built-in key"),
    NONE("No key set");

    companion object {
        fun of(override: String?, baked: String): KeyStatus = when {
            !override.isNullOrBlank() -> YOURS
            baked.isNotBlank() -> BUILT_IN
            else -> NONE
        }
    }
}
