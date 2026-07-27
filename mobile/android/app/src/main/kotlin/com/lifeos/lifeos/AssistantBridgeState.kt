package com.lifeos.lifeos

class AssistantBridgeState(
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val pendingCapacity: Int = 32,
    private val terminalCapacity: Int = 256,
    private val pendingExpiryMillis: Long = 5 * 60 * 1000L,
    private val terminalExpiryMillis: Long = 30 * 60 * 1000L,
) {
    private val pending = linkedMapOf<String, Long>()
    private val terminal = linkedMapOf<String, Pair<String, Long>>()

    fun enqueue(id: String): Boolean {
        prune()
        if (id in pending || id in terminal) return false
        if (pending.size >= pendingCapacity) {
            terminalize(id, "discarded")
            return false
        }
        pending[id] = clock()
        return true
    }

    fun drain(): List<String> {
        prune()
        return pending.keys.toList()
    }

    fun complete(id: String, outcome: String): Boolean {
        if (outcome != "acknowledged" && outcome != "discarded") return false
        prune()
        terminal[id]?.let { return it.first == outcome }
        if (pending.remove(id) == null) return false
        terminalize(id, outcome)
        return true
    }

    private fun prune() {
        val now = clock()
        pending.filterValues { now - it >= pendingExpiryMillis }.keys.toList().forEach {
            pending.remove(it)
            terminalize(it, "discarded")
        }
        terminal.filterValues { now - it.second >= terminalExpiryMillis }.keys.forEach(terminal::remove)
    }

    private fun terminalize(id: String, outcome: String) {
        terminal[id] = outcome to clock()
        while (terminal.size > terminalCapacity) terminal.remove(terminal.keys.first())
    }
}
