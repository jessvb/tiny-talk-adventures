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

    @Test fun notifiesListenerOnChange() {
        val nav = Navigator(FakeConsentStore(true))
        var n = 0
        nav.onChange = { n++ }
        nav.goTo(Screen.STORY)
        nav.back()
        assertEquals(2, n)
    }
}
