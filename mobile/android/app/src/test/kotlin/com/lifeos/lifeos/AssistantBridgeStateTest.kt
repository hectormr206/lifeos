package com.lifeos.lifeos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AssistantBridgeStateTest {
    @Test
    fun `cold and warm IDs are retained once and drained in arrival order`() {
        val state = AssistantBridgeState()

        assertTrue(state.enqueue("cold-1"))
        assertFalse(state.enqueue("cold-1"))
        assertTrue(state.enqueue("warm-2"))

        assertEquals(listOf("cold-1", "warm-2"), state.consumeAll())
        assertEquals(emptyList<String>(), state.consumeAll())
    }

    @Test
    fun `a delivered warm ID is not retained for a later cold drain`() {
        val state = AssistantBridgeState()

        assertTrue(state.markDelivered("warm-1"))
        assertFalse(state.enqueue("warm-1"))
        assertTrue(state.enqueue("next-2"))

        assertEquals(listOf("next-2"), state.consumeAll())
    }
}
