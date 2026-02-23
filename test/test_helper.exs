ExUnit.start()

# Modules we stub in tests via Mimic (e.g. the WhatsApp delivery over the Graph API,
# so a webhook round-trip test can capture the outbound message without the network).
Mimic.copy(Pepe.Webhooks.WhatsApp)
Mimic.copy(Req)
Mimic.copy(Pepe.LLM)
