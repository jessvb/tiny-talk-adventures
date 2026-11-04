package com.jessvb.tinytalk.keys

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.keys.KeyStore
import java.security.KeyStore as JKeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
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
class SecretsStore internal constructor(
    context: Context,
    prefsName: String,
    private val keyAlias: String,
    private val keyProvider: (() -> SecretKey)? = null,
) : KeyStore {
    constructor(context: Context) : this(context, PROD_PREFS, PROD_ALIAS)

    private val prefs = context.applicationContext
        .getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    private fun secretKey(): SecretKey = keyProvider?.invoke() ?: key()

    override fun get(name: KeyName): String? {
        synchronized(LOCK) {
        val blob = prefs.getString(name.name, null) ?: return null
        return try {
            val raw = Base64.decode(blob, Base64.NO_WRAP)
            require(raw.size > IV_BYTES)
            val c = Cipher.getInstance(TRANSFORM)
            c.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, raw, 0, IV_BYTES))
            String(c.doFinal(raw, IV_BYTES, raw.size - IV_BYTES), Charsets.UTF_8)
                .takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            if (isDeterministicCorruption(e)) {
                Log.w(TAG, "corrupt stored value for ${name.name}; removing (${e.javaClass.simpleName})")
                prefs.edit().remove(name.name).apply()
            } else {
                // Possibly a transient Keystore error: keep the blob, just report absent.
                Log.w(TAG, "could not read ${name.name}; keeping entry (${e.javaClass.simpleName})")
            }
            null
        }
        }
    }

    private fun isDeterministicCorruption(e: Exception) =
        e is IllegalArgumentException || e is AEADBadTagException ||
            e is KeyPermanentlyInvalidatedException || e is UnrecoverableKeyException

    override fun set(name: KeyName, value: String?) = synchronized(LOCK) {
        if (value.isNullOrBlank()) {
            prefs.edit().remove(name.name).apply()
            return@synchronized
        }
        try {
            val c = Cipher.getInstance(TRANSFORM)
            c.init(Cipher.ENCRYPT_MODE, secretKey())
            val ct = c.doFinal(value.trim().toByteArray(Charsets.UTF_8))
            val blob = Base64.encodeToString(c.iv + ct, Base64.NO_WRAP)
            prefs.edit().putString(name.name, blob).apply()
        } catch (e: Exception) {
            Log.w(TAG, "could not store value for ${name.name} (${e.javaClass.simpleName})")
        }
    }

    private fun key(): SecretKey = synchronized(LOCK) {
        val ks = JKeyStore.getInstance(ANDROID_KS).apply { load(null) }
        (ks.getKey(keyAlias, null) as? SecretKey)?.let { return@synchronized it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KS)
        gen.init(
            KeyGenParameterSpec.Builder(
                keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        gen.generateKey()
    }

    private companion object {
        const val TAG = "SecretsStore"
        const val ANDROID_KS = "AndroidKeyStore"
        const val PROD_PREFS = "tinytalk_secrets"
        const val PROD_ALIAS = "tinytalk_secrets_v1"
        /** Process-wide: several instances may exist; guards key creation and prefs read/modify/write. */
        val LOCK = Any()
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}
