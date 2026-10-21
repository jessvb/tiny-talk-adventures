package com.jessvb.tinytalk.core.facts

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * On-disk fact cache (animal -> facts), mirroring AnimalFactsCache in
 * AnimalFactsAPIClient.swift. Facts are public animal trivia, not child data.
 * Writes go to a temp file in the same directory, then rename, so a crash
 * never leaves a half-written file; a missing or corrupt file loads as empty.
 */
class AnimalFactsCache(private val file: File) {
    private val lock = Any()
    private val serializer = MapSerializer(String.serializer(), ListSerializer(String.serializer()))

    fun load(): Map<String, List<String>> = synchronized(lock) {
        try {
            if (!file.isFile) emptyMap() else Json.decodeFromString(serializer, file.readText())
        } catch (e: Exception) {
            emptyMap()
        }
    }

    fun save(cache: Map<String, List<String>>) = synchronized(lock) {
        try {
            val dir = file.absoluteFile.parentFile
            dir.mkdirs()
            val tmp = File.createTempFile("animal_facts", ".tmp", dir)
            try {
                tmp.writeText(Json.encodeToString(serializer, cache))
                Files.move(
                    tmp.toPath(), file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
                )
            } finally {
                tmp.delete()
            }
        } catch (e: IOException) {
            // Best effort, like the Swift `try?`: a failed save only means a re-fetch later.
        }
    }
}
