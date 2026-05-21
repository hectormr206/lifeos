"""LifeOS nano-agents — small CPU-only specialists.

Architecture (per PRD-nano-agents-v1):
    Main brain (Qwen 35B on GPU port 8080) → handles open conversation.
    Nano-agents (Qwen 0.8B on CPU port 8090) → handle structured extraction
        from natural language where the regex fast-path can't match.

Module layout:
    runtime  : HTTP client to the nano llama-server (port 8090).
    extractor: entity extractor agent. Recibe texto y retorna dict
               estructurado con domain, people, amounts, dates, etc.
"""
