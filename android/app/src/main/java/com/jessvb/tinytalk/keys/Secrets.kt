package com.jessvb.tinytalk.keys

import com.jessvb.tinytalk.BuildConfig
import com.jessvb.tinytalk.core.keys.KeyName

/** Baked-in keys from android/local.secrets.properties; empty string when not configured. */
object Secrets {
    fun baked(name: KeyName): String = when (name) {
        KeyName.GROQ -> BuildConfig.GROQ_API_KEY
        KeyName.CLOUDFLARE_ACCOUNT_ID -> BuildConfig.CLOUDFLARE_ACCOUNT_ID
        KeyName.CLOUDFLARE_TOKEN -> BuildConfig.CLOUDFLARE_API_TOKEN
        KeyName.API_NINJAS -> BuildConfig.API_NINJAS_KEY
    }
}
