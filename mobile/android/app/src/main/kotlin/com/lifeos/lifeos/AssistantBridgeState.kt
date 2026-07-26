package com.lifeos.lifeos

/**
 * Process-local delivery state for Android assistant activations.
 *
 * An ID is retained exactly once until Dart drains it, or marked delivered when
 * a warm Flutter engine receives it immediately. Keeping the ID set lets the
 * native and Dart boundaries reject a lifecycle race without collapsing
 * separate assistant invocations.
 */
class AssistantBridgeState {
    private val pendingIds = ArrayDeque<String>()
    private val observedIds = mutableSetOf<String>()

    fun enqueue(id: String): Boolean {
        if (!observedIds.add(id)) return false
        pendingIds.addLast(id)
        return true
    }

    fun markDelivered(id: String): Boolean = observedIds.add(id)

    fun consumeAll(): List<String> {
        val launches = pendingIds.toList()
        pendingIds.clear()
        return launches
    }
}
