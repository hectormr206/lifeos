package com.lifeos.lifeos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AssistantBridgeStateTest {
    @Test
    fun `drain retains IDs until one terminal completion`() {
        val state = AssistantBridgeState(clock = { 0L })
        assertTrue(state.enqueue("cold"))
        assertEquals(listOf("cold"), state.drain())
        assertEquals(listOf("cold"), state.drain())
        assertTrue(state.complete("cold", "acknowledged"))
        assertTrue(state.complete("cold", "acknowledged"))
        assertFalse(state.complete("cold", "discarded"))
        assertEquals(emptyList<String>(), state.drain())
    }

    @Test
    fun `capacity and expiry terminalize IDs deterministically`() {
        var now = 0L
        val state = AssistantBridgeState(
            clock = { now },
            pendingCapacity = 1,
            pendingExpiryMillis = 10L,
        )
        assertTrue(state.enqueue("first"))
        assertFalse(state.enqueue("excess"))
        assertEquals(listOf("first"), state.drain())
        now = 11L
        assertEquals(emptyList<String>(), state.drain())
        assertFalse(state.enqueue("first"))
    }
}
