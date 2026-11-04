package com.jessvb.tinytalk.core

import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertThrows
import org.junit.Test

class FailuresTest {
    @Test fun recoverableThrowablesReturn() {
        IllegalStateException("x").rethrowIfFatal()
        ExceptionInInitializerError(IllegalArgumentException("x")).rethrowIfFatal()
        NoClassDefFoundError("x").rethrowIfFatal()
    }

    @Test fun cancellationAndVmErrorsAreRethrown() {
        assertThrows(CancellationException::class.java) { CancellationException("x").rethrowIfFatal() }
        assertThrows(OutOfMemoryError::class.java) { OutOfMemoryError("x").rethrowIfFatal() }
        assertThrows(StackOverflowError::class.java) { StackOverflowError().rethrowIfFatal() }
    }
}
