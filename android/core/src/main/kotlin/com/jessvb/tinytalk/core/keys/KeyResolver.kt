package com.jessvb.tinytalk.core.keys

enum class KeyName { GROQ, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TOKEN, API_NINJAS }

/** Device-local override storage. A null or blank [set] value clears the override. */
interface KeyStore {
    fun get(name: KeyName): String?
    fun set(name: KeyName, value: String?)
}

/**
 * Resolves the key to use: a non-blank (trimmed) Settings override wins, else the
 * non-blank baked-in key, else null. The override is re-read on every call.
 */
class KeyResolver(private val baked: String, private val override: () -> String?) {
    fun current(): String? =
        override()?.trim()?.takeIf { it.isNotEmpty() }
            ?: baked.trim().takeIf { it.isNotEmpty() }
}
