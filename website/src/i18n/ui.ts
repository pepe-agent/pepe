// UI + landing copy per locale. Small inline HTML (e.g. <span class="grad">) is
// rendered with set:html in the templates.

export const locales = ["en", "es", "pt-br", "pt-pt"] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = "en";

export const localeNames: Record<Locale, string> = {
  en: "English",
  es: "Español",
  "pt-br": "Português (BR)",
  "pt-pt": "Português (PT)",
};

export const ui = {
  en: {
    "nav.features": "Features",
    "nav.surfaces": "Surfaces",
    "nav.channels": "Channels",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · self-hosted",
    "hero.title": 'The AI agent runtime<br/>you <span class="grad">run yourself</span>.',
    "hero.lead":
      "Define agents, connect any OpenAI-compatible model, and run a real tool-calling loop. Reach the same agents from your terminal, an HTTP API, a WebSocket, and messaging channels. No vendor, no database, your keys.",
    "hero.cta_start": "Get started →",
    "hero.cta_docs": "Read the docs",

    "surfaces.title": "One agent, four surfaces",
    "surfaces.sub":
      "Every agent you define is reachable the same way from wherever you need it. Same loop, same memory, same tools.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "One-shot runs and an interactive REPL.",
    "surf.http.t": "HTTP API",
    "surf.http.d": "OpenAI-compatible /v1/chat/completions and /v1/models.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "A Phoenix channel for live, streaming conversations.",
    "surf.ch.t": "Channels",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "Everything an agent needs, nothing it doesn't",
    "features.sub":
      "A small, honest runtime. Config lives in files, secrets are env references, and there is no database to run.",
    "f.model.t": "Any model, with failover",
    "f.model.d":
      "Connect any OpenAI-compatible endpoint. Set a fallback chain that advances on transient errors.",
    "f.tools.t": "Real tool-calling loop",
    "f.tools.d":
      "Built-in tools for shell, files, web, running scripts, and sending files back to the chat. Add your own in minutes.",
    "f.channels.t": "Messaging channels",
    "f.channels.d":
      "Bind an agent to a Telegram bot or a webhook channel, with native handoff, admin vs support modes, and per-connection scoping.",
    "f.cron.t": "Scheduled tasks",
    "f.cron.d":
      "Timezone-aware cron in an in-app scheduler. The agent can create its own from a conversation, gated by your approval.",
    "f.plugins.t": "Plugins at runtime",
    "f.plugins.d":
      "Drop in new tools or channels with no rebuild. A deep security scan runs on install, and providers declare their own config form.",
    "f.sandbox.t": "Sandbox & permissions",
    "f.sandbox.d":
      "Risky tools pass an approval gate by default. Guardrails block catastrophic commands, and an opt-in wrapper adds real isolation.",
    "f.tenant.t": "Multi-tenant",
    "f.tenant.d":
      "Optional companies wall off agents, models, channels and automations per tenant, with per-company usage and billing.",
    "f.traces.t": "Traces & usage",
    "f.traces.d":
      "Every run is recorded. What triggered it, the tools it called, tokens and cost. Open one to replay it step by step.",
    "f.nodb.t": "No database",
    "f.nodb.d":
      "Config is a single JSON file at ~/.pepe. Secrets are written as ${ENV_VAR} and resolved at read time.",

    "channels.title": "Meet people where they are",
    "channels.sub":
      "Connect an agent to a channel and people just chat with it. Files, handoff and scoping come built in.",

    "how.title": "How the loop works",
    "how.sub":
      "The runtime calls the model, runs any tool calls, feeds the results back, and repeats until a final answer.",
    "how.1.t": "Call the model",
    "how.1.d": "Send the conversation and the agent's tool specs to the model (with failover).",
    "how.2.t": "Run tool calls",
    "how.2.d": "Execute what the model asked for. Shell, files, web. Through the permission gate.",
    "how.3.t": "Feed results back",
    "how.3.d": "Append each tool result to the conversation and call the model again.",
    "how.4.t": "Answer & deliver",
    "how.4.d": "Return the final reply on whatever surface asked. And record the whole run as a trace.",

    "cta.title": "Run your own agents in minutes",
    "cta.sub": "Open source. Bring your own model. Your machine, your keys, your data.",
    "cta.start": "Quickstart",
    "cta.github": "Star on GitHub",
    "why.title": "Why \"Pepe\"?",
    "why.body": "He comes from Chespirito's beloved comedy universe (El Chapulín Colorado, adored across Brazil as the Chapolin, plus El Chavo del Ocho) that generations across Latin America grew up with. His whole thing? He did exactly what he was told. No arguing, no improvising beyond the order. Which, funnily enough, describes an AI agent runtime perfectly.",

    "foot.tagline":
      "An Elixir/OTP AI agent runtime. Self-hosted, model-agnostic, no database. Not affiliated with any model provider.",
    "foot.docs": "Docs",
    "foot.guides": "Guides",
    "foot.project": "Project",
  },

  es: {
    "nav.features": "Características",
    "nav.surfaces": "Superficies",
    "nav.channels": "Canales",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · autoalojado",
    "hero.title": 'El runtime de agentes IA<br/>que <span class="grad">ejecutas tú mismo</span>.',
    "hero.lead":
      "Define agentes, conecta cualquier modelo compatible con OpenAI y ejecuta un bucle real de llamada a herramientas. Alcanza los mismos agentes desde tu terminal, una API HTTP, un WebSocket y canales de mensajería. Sin proveedor, sin base de datos, con tus claves.",
    "hero.cta_start": "Empezar →",
    "hero.cta_docs": "Leer la documentación",

    "surfaces.title": "Un agente, cuatro superficies",
    "surfaces.sub":
      "Cada agente que defines es accesible de la misma forma desde donde lo necesites. Mismo bucle, misma memoria, mismas herramientas.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "Ejecuciones puntuales y un REPL interactivo.",
    "surf.http.t": "API HTTP",
    "surf.http.d": "/v1/chat/completions y /v1/models compatibles con OpenAI.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "Un canal Phoenix para conversaciones en vivo por streaming.",
    "surf.ch.t": "Canales",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "Todo lo que un agente necesita, nada más",
    "features.sub":
      "Un runtime pequeño y honesto. La configuración vive en archivos, los secretos son referencias a variables de entorno y no hay base de datos que ejecutar.",
    "f.model.t": "Cualquier modelo, con failover",
    "f.model.d":
      "Conecta cualquier endpoint compatible con OpenAI. Define una cadena de respaldo que avanza ante errores transitorios.",
    "f.tools.t": "Bucle real de herramientas",
    "f.tools.d":
      "Herramientas integradas para shell, archivos, web, ejecutar scripts y enviar archivos al chat. Añade las tuyas en minutos.",
    "f.channels.t": "Canales de mensajería",
    "f.channels.d":
      "Vincula un agente a un bot de Telegram o a un canal por webhook, con traspaso nativo, modos admin/soporte y alcance por conexión.",
    "f.cron.t": "Tareas programadas",
    "f.cron.d":
      "Cron con zona horaria en un planificador interno. El agente puede crear las suyas desde una conversación, con tu aprobación.",
    "f.plugins.t": "Plugins en tiempo de ejecución",
    "f.plugins.d":
      "Añade herramientas o canales sin recompilar. Un escaneo de seguridad profundo corre al instalar y los proveedores declaran su propio formulario.",
    "f.sandbox.t": "Sandbox y permisos",
    "f.sandbox.d":
      "Las herramientas riesgosas pasan por una aprobación por defecto. Los guardrails bloquean comandos catastróficos y un wrapper opcional añade aislamiento real.",
    "f.tenant.t": "Multiinquilino",
    "f.tenant.d":
      "Las empresas opcionales aíslan agentes, modelos, canales y automatizaciones por inquilino, con uso y facturación por empresa.",
    "f.traces.t": "Trazas y uso",
    "f.traces.d":
      "Cada ejecución se registra. Qué la disparó, las herramientas usadas, tokens y coste. Abre una para reproducirla paso a paso.",
    "f.nodb.t": "Sin base de datos",
    "f.nodb.d":
      "La configuración es un único JSON en ~/.pepe. Los secretos se escriben como ${ENV_VAR} y se resuelven al leer.",

    "channels.title": "Encuentra a las personas donde están",
    "channels.sub":
      "Conecta un agente a un canal y la gente simplemente chatea con él. Archivos, traspaso y alcance vienen incluidos.",

    "how.title": "Cómo funciona el bucle",
    "how.sub":
      "El runtime llama al modelo, ejecuta las herramientas, devuelve los resultados y repite hasta una respuesta final.",
    "how.1.t": "Llamar al modelo",
    "how.1.d": "Envía la conversación y las herramientas del agente al modelo (con failover).",
    "how.2.t": "Ejecutar herramientas",
    "how.2.d": "Ejecuta lo que pidió el modelo. Shell, archivos, web. Tras la aprobación.",
    "how.3.t": "Devolver resultados",
    "how.3.d": "Añade cada resultado a la conversación y vuelve a llamar al modelo.",
    "how.4.t": "Responder y entregar",
    "how.4.d": "Devuelve la respuesta final en la superficie que preguntó. Y registra la ejecución como una traza.",

    "cta.title": "Ejecuta tus propios agentes en minutos",
    "cta.sub": "Código abierto. Trae tu propio modelo. Tu máquina, tus claves, tus datos.",
    "cta.start": "Inicio rápido",
    "cta.github": "Estrella en GitHub",
    "why.title": "¿Por qué \"Pepe\"?",
    "why.body": "Viene del querido universo de comedia de Chespirito (El Chapulín Colorado y El Chavo del Ocho) con el que crecieron generaciones en toda América Latina. ¿Su sello? Hacía exactamente lo que le pedían. Sin discutir, sin improvisar más allá de la orden. Lo que, curiosamente, describe a la perfección un runtime de agentes de IA.",

    "foot.tagline":
      "Un runtime de agentes IA en Elixir/OTP. Autoalojado, agnóstico de modelo, sin base de datos. Sin afiliación con ningún proveedor de modelos.",
    "foot.docs": "Docs",
    "foot.guides": "Guías",
    "foot.project": "Proyecto",
  },

  "pt-br": {
    "nav.features": "Recursos",
    "nav.surfaces": "Superfícies",
    "nav.channels": "Canais",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · auto-hospedado",
    "hero.title": 'O runtime de agentes de IA<br/>que <span class="grad">você mesmo roda</span>.',
    "hero.lead":
      "Defina agentes, conecte qualquer modelo compatível com OpenAI e rode um loop real de chamada de ferramentas. Alcance os mesmos agentes pelo terminal, uma API HTTP, um WebSocket e canais de mensagem. Sem fornecedor, sem banco de dados, com suas chaves.",
    "hero.cta_start": "Começar →",
    "hero.cta_docs": "Ler a documentação",

    "surfaces.title": "Um agente, quatro superfícies",
    "surfaces.sub":
      "Cada agente que você define é alcançável do mesmo jeito de onde precisar. Mesmo loop, mesma memória, mesmas ferramentas.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "Execuções pontuais e um REPL interativo.",
    "surf.http.t": "API HTTP",
    "surf.http.d": "/v1/chat/completions e /v1/models compatíveis com OpenAI.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "Um canal Phoenix para conversas ao vivo com streaming.",
    "surf.ch.t": "Canais",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "Tudo que um agente precisa, nada além",
    "features.sub":
      "Um runtime pequeno e honesto. A config vive em arquivos, segredos são referências de env, e não há banco de dados pra rodar.",
    "f.model.t": "Qualquer modelo, com failover",
    "f.model.d":
      "Conecte qualquer endpoint compatível com OpenAI. Defina uma cadeia de fallback que avança em erros transitórios.",
    "f.tools.t": "Loop real de ferramentas",
    "f.tools.d":
      "Ferramentas nativas para shell, arquivos, web, rodar scripts e enviar arquivos de volta ao chat. Adicione as suas em minutos.",
    "f.channels.t": "Canais de mensagem",
    "f.channels.d":
      "Vincule um agente a um bot do Telegram ou a um canal por webhook, com handoff nativo, modos admin/suporte e escopo por conexão.",
    "f.cron.t": "Tarefas agendadas",
    "f.cron.d":
      "Cron com fuso horário num agendador interno. O agente pode criar as próprias por conversa, com a sua aprovação.",
    "f.plugins.t": "Plugins em runtime",
    "f.plugins.d":
      "Adicione ferramentas ou canais sem recompilar. Uma varredura de segurança profunda roda na instalação, e cada provider declara seu formulário.",
    "f.sandbox.t": "Sandbox e permissões",
    "f.sandbox.d":
      "Ferramentas arriscadas passam por aprovação por padrão. Guardrails bloqueiam comandos catastróficos, e um wrapper opcional adiciona isolamento real.",
    "f.tenant.t": "Multiempresa",
    "f.tenant.d":
      "Empresas opcionais isolam agentes, modelos, canais e automações por tenant, com uso e cobrança por empresa.",
    "f.traces.t": "Traces e uso",
    "f.traces.d":
      "Toda execução é registrada. O que a disparou, as ferramentas usadas, tokens e custo. Abra uma para dar replay passo a passo.",
    "f.nodb.t": "Sem banco de dados",
    "f.nodb.d":
      "A config é um único JSON em ~/.pepe. Segredos são escritos como ${ENV_VAR} e resolvidos na leitura.",

    "channels.title": "Encontre as pessoas onde elas estão",
    "channels.sub":
      "Conecte um agente a um canal e as pessoas simplesmente conversam com ele. Arquivos, handoff e escopo já vêm prontos.",

    "how.title": "Como o loop funciona",
    "how.sub":
      "O runtime chama o modelo, roda as chamadas de ferramenta, devolve os resultados e repete até uma resposta final.",
    "how.1.t": "Chamar o modelo",
    "how.1.d": "Envia a conversa e as ferramentas do agente ao modelo (com failover).",
    "how.2.t": "Rodar ferramentas",
    "how.2.d": "Executa o que o modelo pediu. Shell, arquivos, web. Após a aprovação.",
    "how.3.t": "Devolver resultados",
    "how.3.d": "Anexa cada resultado à conversa e chama o modelo de novo.",
    "how.4.t": "Responder e entregar",
    "how.4.d": "Devolve a resposta final na superfície que pediu. E registra a execução como um trace.",

    "cta.title": "Rode seus próprios agentes em minutos",
    "cta.sub": "Código aberto. Traga seu modelo. Sua máquina, suas chaves, seus dados.",
    "cta.start": "Início rápido",
    "cta.github": "Dar estrela no GitHub",
    "why.title": "Por que \"Pepe\"?",
    "why.body": "Ele vem do querido universo de comédia do Chespirito (o Chapolin Colorado e o Chaves) com que gerações da América Latina cresceram. A marca dele? Fazia exatamente o que mandavam. Sem discutir, sem improvisar além da ordem. O que, curiosamente, descreve um runtime de agentes de IA perfeitamente.",

    "foot.tagline":
      "Um runtime de agentes de IA em Elixir/OTP. Auto-hospedado, agnóstico de modelo, sem banco de dados. Sem afiliação a qualquer fornecedor de modelos.",
    "foot.docs": "Docs",
    "foot.guides": "Guias",
    "foot.project": "Projeto",
  },

  "pt-pt": {
    "nav.features": "Funcionalidades",
    "nav.surfaces": "Superfícies",
    "nav.channels": "Canais",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · auto-alojado",
    "hero.title": 'O runtime de agentes de IA<br/>que <span class="grad">executas tu próprio</span>.',
    "hero.lead":
      "Define agentes, liga qualquer modelo compatível com OpenAI e corre um ciclo real de chamada de ferramentas. Alcança os mesmos agentes pelo terminal, uma API HTTP, um WebSocket e canais de mensagens. Sem fornecedor, sem base de dados, com as tuas chaves.",
    "hero.cta_start": "Começar →",
    "hero.cta_docs": "Ler a documentação",

    "surfaces.title": "Um agente, quatro superfícies",
    "surfaces.sub":
      "Cada agente que defines é acessível da mesma forma a partir de onde precisares. Mesmo ciclo, mesma memória, mesmas ferramentas.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "Execuções pontuais e um REPL interativo.",
    "surf.http.t": "API HTTP",
    "surf.http.d": "/v1/chat/completions e /v1/models compatíveis com OpenAI.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "Um canal Phoenix para conversas ao vivo com streaming.",
    "surf.ch.t": "Canais",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "Tudo o que um agente precisa, nada além",
    "features.sub":
      "Um runtime pequeno e honesto. A configuração vive em ficheiros, os segredos são referências de ambiente, e não há base de dados para correr.",
    "f.model.t": "Qualquer modelo, com failover",
    "f.model.d":
      "Liga qualquer endpoint compatível com OpenAI. Define uma cadeia de recurso que avança em erros transitórios.",
    "f.tools.t": "Ciclo real de ferramentas",
    "f.tools.d":
      "Ferramentas nativas para shell, ficheiros, web, correr scripts e enviar ficheiros de volta ao chat. Adiciona as tuas em minutos.",
    "f.channels.t": "Canais de mensagens",
    "f.channels.d":
      "Liga um agente a um bot do Telegram ou a um canal por webhook, com transferência nativa, modos admin/suporte e âmbito por ligação.",
    "f.cron.t": "Tarefas agendadas",
    "f.cron.d":
      "Cron com fuso horário num agendador interno. O agente pode criar as próprias por conversa, com a tua aprovação.",
    "f.plugins.t": "Plugins em tempo de execução",
    "f.plugins.d":
      "Adiciona ferramentas ou canais sem recompilar. Uma análise de segurança profunda corre na instalação, e cada provider declara o seu formulário.",
    "f.sandbox.t": "Sandbox e permissões",
    "f.sandbox.d":
      "Ferramentas arriscadas passam por aprovação por omissão. As guardas bloqueiam comandos catastróficos, e um wrapper opcional adiciona isolamento real.",
    "f.tenant.t": "Multi-inquilino",
    "f.tenant.d":
      "Empresas opcionais isolam agentes, modelos, canais e automações por inquilino, com utilização e faturação por empresa.",
    "f.traces.t": "Traces e utilização",
    "f.traces.d":
      "Cada execução é registada. O que a despoletou, as ferramentas usadas, tokens e custo. Abre uma para a repetir passo a passo.",
    "f.nodb.t": "Sem base de dados",
    "f.nodb.d":
      "A configuração é um único JSON em ~/.pepe. Os segredos são escritos como ${ENV_VAR} e resolvidos na leitura.",

    "channels.title": "Encontra as pessoas onde elas estão",
    "channels.sub":
      "Liga um agente a um canal e as pessoas simplesmente falam com ele. Ficheiros, transferência e âmbito já vêm prontos.",

    "how.title": "Como funciona o ciclo",
    "how.sub":
      "O runtime chama o modelo, corre as chamadas de ferramenta, devolve os resultados e repete até uma resposta final.",
    "how.1.t": "Chamar o modelo",
    "how.1.d": "Envia a conversa e as ferramentas do agente ao modelo (com failover).",
    "how.2.t": "Correr ferramentas",
    "how.2.d": "Executa o que o modelo pediu. Shell, ficheiros, web. Após a aprovação.",
    "how.3.t": "Devolver resultados",
    "how.3.d": "Anexa cada resultado à conversa e chama o modelo de novo.",
    "how.4.t": "Responder e entregar",
    "how.4.d": "Devolve a resposta final na superfície que pediu. E regista a execução como um trace.",

    "cta.title": "Corre os teus próprios agentes em minutos",
    "cta.sub": "Código aberto. Traz o teu modelo. A tua máquina, as tuas chaves, os teus dados.",
    "cta.start": "Início rápido",
    "cta.github": "Dar estrela no GitHub",
    "why.title": "Porquê \"Pepe\"?",
    "why.body": "Vem do adorado universo de comédia do Chespirito (o Chapulín Colorado e o Chaves) com que gerações da América Latina cresceram. A imagem de marca dele? Fazia exatamente o que lhe mandavam. Sem discutir, sem improvisar além da ordem. O que, curiosamente, descreve na perfeição um runtime de agentes de IA.",

    "foot.tagline":
      "Um runtime de agentes de IA em Elixir/OTP. Auto-alojado, agnóstico de modelo, sem base de dados. Sem afiliação a qualquer fornecedor de modelos.",
    "foot.docs": "Docs",
    "foot.guides": "Guias",
    "foot.project": "Projeto",
  },
} as const;

export function t(locale: Locale) {
  const dict = ui[locale] ?? ui[defaultLocale];
  return (key: keyof typeof ui["en"]) => (dict as Record<string, string>)[key] ?? key;
}
