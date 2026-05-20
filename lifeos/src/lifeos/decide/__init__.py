"""LifeOS Decision Engine — cross-domain reasoning over your own data.

The decision engine is a prompt composer + retriever pair. For each
question type:
  1. Identify which domains hold relevant evidence.
  2. Fetch a focused slice (top-K most relevant rows).
  3. Build a context block summarized for the LLM.
  4. Ask the brain with that context.
  5. Return the answer plus references to the entries that informed it.

P4 ships two question types:
  - purchase consult: "¿puedo comprar X?" → finance state + impulse history
  - symptom pattern : on logging a symptom, find historical recurrences

The brain.ask wrapping is INJECTED rather than imported, so the lifeos
package stays free of the axi dependency. The dashboard supplies its own
ask callable when invoking the engine.
"""

__all__ = ["purchase", "symptom", "query_parser"]
