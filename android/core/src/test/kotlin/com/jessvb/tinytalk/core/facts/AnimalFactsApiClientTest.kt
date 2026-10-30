package com.jessvb.tinytalk.core.facts

import java.io.File
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AnimalFactsApiClientTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer(); server.start() }
    @After fun tearDown() { server.shutdown() }

    private fun client(key: String? = "fake-key") =
        AnimalFactsApiClient(apiKey = { key }, host = server.url("/").toString().trimEnd('/'))

    private val body = """[{"name":"Fox","characteristics":{"diet":"Omnivore","habitat":"forests","color":"Red"}}]"""

    @Test fun blankOrNullKeyMakesNoRequest() = runBlocking {
        assertNull(client(null).fetchFacts("fox"))
        assertNull(client("").fetchFacts("fox"))
        assertNull(client("   ").fetchFacts("fox"))
        assertEquals(0, server.requestCount)
    }

    @Test fun okResponseExtractsFactsAndSendsKeyAndName() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody(body))
        val facts = client().fetchFacts("fox")
        assertEquals(listOf("its diet is Omnivore", "it lives in forests", "its coloring is Red"), facts)
        val req = server.takeRequest()
        assertEquals("fake-key", req.getHeader("X-Api-Key"))
        assertEquals("/v1/animals?name=fox", req.path)
    }

    @Test fun emptyRecordsGiveEmptyList() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))
        assertEquals(emptyList<String>(), client().fetchFacts("fox"))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""[{"name":"Fox"}]"""))
        assertEquals(emptyList<String>(), client().fetchFacts("fox"))
    }

    @Test fun nonOkIsNull() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(500).setBody("boom"))
        assertNull(client().fetchFacts("fox"))
        server.enqueue(MockResponse().setResponseCode(403).setBody("nope"))
        assertNull(client().fetchFacts("fox"))
    }

    @Test fun malformedJsonIsNull() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("not json"))
        assertNull(client().fetchFacts("fox"))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"characteristics":1}"""))
        assertNull(client().fetchFacts("fox"))
    }

    @Test fun ioFailureIsNull() = runBlocking {
        val c = client()
        server.shutdown()
        assertNull(c.fetchFacts("fox"))
    }
}

class AnimalFactsCacheTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun roundTrip() {
        val f = File(tmp.root, "sub/cache.json")
        val cache = AnimalFactsCache(f)
        assertEquals(emptyMap<String, List<String>>(), cache.load())
        cache.save(mapOf("fox" to listOf("a", "b\"quoted\""), "owl" to emptyList()))
        assertEquals(mapOf("fox" to listOf("a", "b\"quoted\""), "owl" to emptyList()), AnimalFactsCache(f).load())
        assertTrue(f.parentFile.listFiles()!!.all { it.name == "cache.json" })
    }

    @Test fun corruptFileLoadsEmpty() {
        val f = File(tmp.root, "cache.json").apply { writeText("{not json") }
        assertEquals(emptyMap<String, List<String>>(), AnimalFactsCache(f).load())
        f.writeText("""{"fox": 3}""")
        assertEquals(emptyMap<String, List<String>>(), AnimalFactsCache(f).load())
    }
}
