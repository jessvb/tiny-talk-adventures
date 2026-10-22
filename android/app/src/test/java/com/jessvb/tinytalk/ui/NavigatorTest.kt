package com.jessvb.tinytalk.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigatorTest {
    private class FakeConsentStore(override var accepted: Boolean = false) : ConsentStore

    @Test fun startsAtOnboardingWithoutConsent() {
        assertEquals(Screen.ONBOARDING, Navigator(FakeConsentStore()).current)
    }

    @Test fun startsAtLandingWhenConsentAlreadyAccepted() {
        assertEquals(Screen.LANDING, Navigator(FakeConsentStore(true)).current)
    }

    @Test fun acceptConsentStoresItAndMovesToLanding() {
        val store = FakeConsentStore()
        val nav = Navigator(store)
        nav.acceptConsent()
        assertTrue(store.accepted)
        assertEquals(Screen.LANDING, nav.current)
    }

    @Test fun decliningKeepsOnboardingAndShowsNotice() {
        val store = FakeConsentStore()
        val nav = Navigator(store)
        assertFalse(nav.declinedNotice)
        nav.declineConsent()
        assertFalse(store.accepted)
        assertEquals(Screen.ONBOARDING, nav.current)
        assertTrue(nav.declinedNotice)
        assertEquals("Nothing is sent until you agree.", Navigator.DECLINED_MESSAGE)
    }

    @Test fun consentPersistsAcrossNewNavigator() {
        val store = FakeConsentStore()
        Navigator(store).acceptConsent()
        assertEquals(Screen.LANDING, Navigator(store).current)
    }

    @Test fun noRouteToAnyScreenWithoutConsent() {
        val nav = Navigator(FakeConsentStore())
        for (s in listOf(Screen.STORY, Screen.SETTINGS, Screen.LANDING)) {
            nav.goTo(s)
            assertEquals(Screen.ONBOARDING, nav.current)
        }
    }

    @Test fun navigatesAndBacksWithConsent() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.STORY)
        assertEquals(Screen.STORY, nav.current)
        assertTrue(nav.back())
        assertEquals(Screen.LANDING, nav.current)
        nav.goTo(Screen.SETTINGS)
        assertTrue(nav.back())
        assertEquals(Screen.LANDING, nav.current)
    }

    @Test fun backFromLandingAndOnboardingIsNotConsumed() {
        assertFalse(Navigator(FakeConsentStore(true)).back())
        assertFalse(Navigator(FakeConsentStore()).back())
    }

    @Test fun cannotNavigateBackToOnboardingAfterConsent() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.ONBOARDING)
        assertEquals(Screen.LANDING, nav.current)
    }

    @Test fun stateFlowFollowsEveryChange() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.STORY)
        assertEquals(Screen.STORY, nav.state.value.screen)
        nav.back()
        assertEquals(Screen.LANDING, nav.state.value.screen)
    }

    // --- Task 10 carry-overs (e), (g) ---

    @Test fun goToLandingFromStoryClearsTheStack() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.STORY)
        nav.goTo(Screen.LANDING)
        assertEquals(Screen.LANDING, nav.current)
        assertFalse(nav.back())
    }

    @Test fun acceptConsentClearsDeclinedNotice() {
        val nav = Navigator(FakeConsentStore())
        nav.declineConsent()
        assertTrue(nav.state.value.declinedNotice)
        nav.acceptConsent()
        assertFalse(nav.declinedNotice)
        assertFalse(nav.state.value.declinedNotice)
        assertEquals(Screen.LANDING, nav.state.value.screen)
    }

    @Test fun declineIsVisibleInState() {
        val nav = Navigator(FakeConsentStore())
        nav.declineConsent()
        assertEquals(NavState(Screen.ONBOARDING, declinedNotice = true), nav.state.value)
    }

    @Test fun duplicateGoToIsANoOp() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.STORY)
        nav.goTo(Screen.STORY)
        assertTrue(nav.back())
        assertEquals(Screen.LANDING, nav.current)
        assertFalse(nav.back())
    }

    @Test fun backAfterDeclineIsNotConsumed() {
        val nav = Navigator(FakeConsentStore())
        nav.declineConsent()
        assertFalse(nav.back())
        assertEquals(Screen.ONBOARDING, nav.current)
    }

    @Test fun settingsFromStoryReturnsToStory() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.STORY)
        nav.goTo(Screen.SETTINGS)
        assertEquals(Screen.SETTINGS, nav.current)
        assertTrue(nav.back())
        assertEquals(Screen.STORY, nav.current)
        assertTrue(nav.back())
        assertEquals(Screen.LANDING, nav.current)
    }

    @Test fun screensNeverNest() {
        val nav = Navigator(FakeConsentStore(true))
        nav.goTo(Screen.STORY)
        nav.goTo(Screen.SETTINGS)
        nav.goTo(Screen.STORY) // already below: pop back to it, no second STORY
        assertEquals(Screen.STORY, nav.current)
        nav.goTo(Screen.SETTINGS)
        nav.goTo(Screen.SETTINGS)
        assertTrue(nav.back())
        assertEquals(Screen.STORY, nav.current)
        assertTrue(nav.back())
        assertEquals(Screen.LANDING, nav.current)
        assertFalse(nav.back())
    }

    // --- Task 10 carry-over (c) ---

    @Test fun revokeConsentClearsItAndReturnsToOnboarding() {
        val store = FakeConsentStore(true)
        val nav = Navigator(store)
        nav.goTo(Screen.STORY)
        nav.goTo(Screen.SETTINGS)
        nav.revokeConsent()
        assertFalse(store.accepted)
        assertEquals(Screen.ONBOARDING, nav.current)
        assertFalse(nav.declinedNotice)
        assertFalse(nav.back())
    }

    @Test fun afterRevokeNothingIsReachableUntilAcceptedAgain() {
        val store = FakeConsentStore(true)
        val nav = Navigator(store)
        nav.revokeConsent()
        nav.goTo(Screen.STORY)
        assertEquals(Screen.ONBOARDING, nav.current)
        assertEquals(Screen.ONBOARDING, Navigator(store).current)
        nav.acceptConsent()
        assertEquals(Screen.LANDING, nav.current)
    }

    @Test fun goToOnboardingStaysRefusedEvenFromSettings() {
        val store = FakeConsentStore(true)
        val nav = Navigator(store)
        nav.goTo(Screen.SETTINGS)
        nav.goTo(Screen.ONBOARDING)
        assertEquals(Screen.SETTINGS, nav.current)
        assertTrue(store.accepted)
    }

    @Test fun revokeWithoutConsentIsHarmless() {
        val nav = Navigator(FakeConsentStore())
        nav.revokeConsent()
        assertEquals(Screen.ONBOARDING, nav.current)
    }
}
