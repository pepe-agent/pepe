# Tests

```bash
mix test
```

The suite stands up a real local OpenAI-compatible mock server (Bandit) and
exercises the full stack: non-streaming chat, SSE streaming, the tool-calling
loop, and the HTTP `/v1` endpoints, all over real TCP. No database needed.

---

[Back to the docs index](../README.md#documentation)
