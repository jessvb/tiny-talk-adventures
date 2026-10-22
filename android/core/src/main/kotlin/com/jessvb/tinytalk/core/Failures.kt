package com.jessvb.tinytalk.core

import kotlinx.coroutines.CancellationException

/**
 * For `catch (t: Throwable)` blocks that keep the app alive: rethrows what must never be
 * swallowed (coroutine cancellation, and VirtualMachineError such as OutOfMemoryError, which
 * is not safely recoverable); returns for everything else.
 *
 * Why catch Throwable at all: an `Error` that is not a VM failure, e.g. an
 * ExceptionInInitializerError / NoClassDefFoundError from a class whose static init fails on
 * Android's runtime only (issue #88), would otherwise escape a `catch (e: Exception)`, kill the
 * coroutine and, unhandled, the whole app.
 */
fun Throwable.rethrowIfFatal() {
    if (this is CancellationException || this is VirtualMachineError) throw this
}
