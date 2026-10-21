package com.jessvb.tinytalk.core.facts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AnimalFactsTest {
    @Test fun findsFox() = assertEquals("fox", AnimalFacts.findNewAnimal("the fox ran", emptyList()))

    @Test fun noAnimalIsNull() = assertNull(AnimalFacts.findNewAnimal("we went to the park", emptyList()))

    @Test fun caseInsensitive() = assertEquals("fox", AnimalFacts.findNewAnimal("A FOX hid", emptyList()))

    @Test fun excludesAlreadyUsed() {
        assertNull(AnimalFacts.findNewAnimal("the fox ran", listOf("fox")))
        assertEquals("owl", AnimalFacts.findNewAnimal("the fox and the owl", listOf("fox")))
    }

    @Test fun aliasesAndPlurals() {
        assertEquals("rabbit", AnimalFacts.findNewAnimal("a little bunny hopped", emptyList()))
        assertEquals("wolf", AnimalFacts.findNewAnimal("howling wolves", emptyList()))
        assertEquals("dog", AnimalFacts.findNewAnimal("two puppies played", emptyList()))
        assertEquals("mouse", AnimalFacts.findNewAnimal("three blind mice", emptyList()))
    }

    @Test fun multiWordBeatsSingleWord() {
        assertEquals("sea turtle", AnimalFacts.findNewAnimal("a sea turtle swam", emptyList()))
        assertEquals("polar bear", AnimalFacts.findNewAnimal("a polar bear slid", emptyList()))
    }

    @Test fun wholeWordOnly() = assertNull(AnimalFacts.findNewAnimal("the foxglove bloomed", emptyList()))

    @Test fun extractFactsTemplatesAndTrimming() {
        val facts = AnimalFacts.extractFacts(
            AnimalCharacteristics(
                mostDistinctiveFeature = "  a bushy tail ", topSpeed = "30 mph", diet = "Omnivore",
                habitat = "forests", slogan = "Clever as a fox", color = "Red", groupBehavior = "Solitary",
                lifespan = "3 years",
            ),
        )
        assertEquals(
            listOf(
                "its most distinctive feature is a bushy tail", "it can move as fast as 30 mph",
                "its diet is Omnivore", "it lives in forests", "Clever as a fox",
                "its coloring is Red", "its group behavior is Solitary", "its lifespan is 3 years",
            ),
            facts,
        )
    }

    @Test fun extractFactsSkipsBlankNullAndUnsafe() {
        val facts = AnimalFacts.extractFacts(
            AnimalCharacteristics(diet = "   ", habitat = "forests", color = "blood red"),
        )
        assertEquals(listOf("it lives in forests"), facts)
    }
}
