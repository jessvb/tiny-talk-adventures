package com.jessvb.tinytalk.keys

import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.keys.KeyResolver
import com.jessvb.tinytalk.core.keys.KeyStore

object AppKeys {
    /** Use as `val apiKey: () -> String? = resolver(name, store)::current`. */
    fun resolver(name: KeyName, store: KeyStore) =
        KeyResolver(Secrets.baked(name)) { store.get(name) }
}
