package com.jessvb.tinytalk.keys

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.keys.KeyStore
import java.security.KeyStore as JKeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Key overrides encrypted with an AES-256-GCM key held in the Android Keystore
 * (androidx.security:security-crypto is deprecated), stored as base64(iv||ciphertext)
 * in plain SharedPreferences. Any failure (corrupt blob, lost keystore key) is treated
 * as "absent"; values are never logged.
 */
class SecretsStore(context: Context) : KeyStore {
    private val prefs = context.applicationContext
        .getSharedPreferences("tinytalk_secrets", Context.MODE_PRIVATE)

    @Synchronized
    override fun get(name: KeyName): String? {
        val blob = prefs.getString(name.name, null) ?: return null
        return try {
            val raw = Base64.decode(blob, Base64.NO_WRAP)
            require(raw.size > IV_BYTES)
            val c = Cipher.getInstance(TRANSFORM)
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, raw, 0, IV_BYTES))
            String(c.doFinal(raw, IV_BYTES, raw.size - IV_BYTES), Charsets.UTF_8)
                .takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            Log.w(TAG, "unreadable stored value for ${name.name}; treating as absent (${e.javaClass.simpleName})")
            prefs.edit().remove(name.name).apply()
            null
        }
    }

    @Synchronized
    override fun set(name: KeyName, value: String?) {
        if (value.isNullOrBlank()) {
            prefs.edit().remove(name.name).apply()
            return
        }
        try {
            val c = Cipher.getInstance(TRANSFORM)
            c.init(Cipher.ENCRYPT_MODE, key())
            val ct = c.doFinal(value.trim().toByteArray(Charsets.UTF_8))
            val blob = Base64.encodeToString(c.iv + ct, Base64.NO_WRAP)
            prefs.edit().putString(name.name, blob).apply()
        } catch (e: Exception) {
            Log.w(TAG, "could not store value for ${name.name} (${e.javaClass.simpleName})")
        }
    }

    private fun key(): SecretKey {
        val ks = JKeyStore.getInstance(ANDROID_KS).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KS)
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    private companion object {
        const val TAG = "SecretsStore"
        const val ANDROID_KS = "AndroidKeyStore"
        const val ALIAS = "tinytalk_secrets_v1"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}
