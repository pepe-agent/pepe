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
    "seo.title": "Pepe, the AI agent runtime you run yourself",
    "nav.features": "Features",
    "nav.surfaces": "Surfaces",
    "nav.channels": "Channels",
    "nav.security": "Security",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · self-hosted",
    "hero.title": 'The AI agent runtime<br/>you <span class="grad">run yourself</span>.',
    "hero.lead":
      "Build a team of virtual employees that handles your inbox, answers customers, digs through your site's data, and runs your Google and Meta ad campaigns: practically anything you'd do yourself. It runs on your own server, with your own keys, under your control.",
    "hero.cta_start": "Get started →",
    "hero.cta_docs": "Read the docs",

    "loops.code_task": "clean up the customer list",
    "loops.code_crit": "no duplicate emails, every row has a valid phone",
    "loops.code_prompt": "# a prompt gets you one answer, and you grade it",
    "loops.code_goal": "# a goal keeps working until a reviewer says it's actually done",
    "loops.title": 'Stop prompting. <span class="grad">Define the outcome.</span>',
    "loops.sub":
      "A prompt buys one turn: the agent answers, and you decide whether it's good enough. That makes you the bottleneck, approver and quality inspector at once, and the work only moves while you're at the keyboard. Give it a goal instead: say what \"done\" means, and Pepe keeps working until an independent reviewer agrees it's met.",
    "loop.turn.t": "Turn loop",
    "loop.turn.d":
      "Calls tools, reads the results, calls more. Stops when it has a real answer, not a guess.",
    "loop.goal.t": "Goal loop",
    "loop.goal.d":
      "You set the objective and what counts as done. An independent reviewer decides, not the agent. Not there yet? It gets the feedback and tries again.",
    "loop.time.t": "Time loop",
    "loop.time.d":
      "Recurring work on a schedule. Runs on its own and catches up on whatever it missed.",

    "surfaces.title": "One agent, four surfaces",
    "surfaces.sub":
      "Define an agent once. Use it from the surface that fits the job, with the same tools and memory.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "One-shot runs and an interactive REPL.",
    "surf.http.t": "HTTP API",
    "surf.http.d":
      "OpenAI-compatible: <code>/chat/completions</code> and <code>/models</code>, from any SDK.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "A WebSocket connection for live, streaming conversations.",
    "surf.ch.t": "Channels",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "The essentials for real agents",
    "features.sub":
      "Model access, tools, automation, plugins, and control in a small self-hosted runtime.",
    "features.enlarge": "Enlarge image",
    "f.model.t": "Any model, with failover",
    "f.model.d":
      "Connect any OpenAI-compatible endpoint. Set a fallback chain that advances on transient errors.",
    "f.routing.t": "Complexity-based routing",
    "f.routing.d":
      "A cheap classification call judges each new conversation. Simple questions downgrade automatically to a lighter model; full power stays for what actually needs it.",
    "f.goal.t": "Goals, not just prompts",
    "f.goal.d":
      "Give an objective and what counts as done. An independent reviewer decides whether it is met, and the agent retries with that feedback until it passes or hits your attempt cap.",
    "f.tools.t": "Real tool-calling loop",
    "f.tools.d":
      "Built-in tools for shell, files, web, scripts, and file delivery. Add your own in minutes.",
    "f.channels.t": "Messaging channels",
    "f.channels.d":
      "Bind an agent to Telegram or webhook channels, with handoff, admin/support modes, and per-connection scope.",
    "f.cron.t": "Scheduled tasks",
    "f.cron.d":
      "Timezone-aware cron inside Pepe. Agents can propose schedules from chat, gated by your approval.",
    "f.plugins.t": "Plugins at runtime",
    "f.plugins.d":
      "Install a plugin, fill in its settings, and give agents new tools or channels right away.",
    "f.learn.t": "Learning & memory",
    "f.learn.d":
      "The agent remembers what it learns (facts, preferences, the people it deals with) and reuses it in later conversations. Read and edit any memory from the dashboard.",
    "f.usage.t": "Spend & message caps",
    "f.usage.d":
      "Cap each company by spend and by messages: a monthly budget in US dollars and a monthly message limit. Both metered live, turning red on the dashboard as they run out.",
    "f.sandbox.t": "Control & safety",
    "f.sandbox.d": "Risky tools ask for approval first. Every run is traced, and command guardrails stay on by default.",
    "f.tenant.t": "Multi-tenant",
    "f.tenant.d":
      "Optional companies isolate agents, models, channels, and automations, with a per-tenant spend cap and message cap you can reset anytime.",
    "f.traces.t": "Traces & usage",
    "f.traces.d":
      "Every run records its trigger, tool calls, tokens, and cost. Open a trace to replay it step by step.",
    "f.support.t": "Full customer support",
    "f.support.d":
      "Answer customers on WhatsApp, Telegram, Slack, or Chatwoot, with human handoff when needed.",

    "channels.title": "Meet people where they are",
    "channels.sub":
      "Connect a channel and the agent answers there. Files, handoff, and scoping are built in.",

    "security.title": "Privacy by design",
    "security.sub":
      "Sensitive data is never sent to an external model in the clear, helping you meet requirements like LGPD, GDPR, and HIPAA.",
    "security.1.t": "What the user sends",
    "security.1.d": "The message exactly as they typed it.",
    "security.2.t": "What reaches the model",
    "security.2.d": "Pepe swaps the sensitive value for a token before the request ever leaves your server.",
    "security.3.t": "What the model answers",
    "security.3.d": "It reasons over the token. It never saw the real value, and never stored it.",
    "security.4.t": "What the user gets back",
    "security.4.d": "Pepe puts the real value back, on your side only.",
    "security.chip.1": "My SSN is 123-45-6789, can you check my order?",
    "security.chip.2": "My SSN is [SSN_1], can you check my order?",
    "security.chip.3": "Found the order for [SSN_1]: it ships tomorrow.",
    "security.chip.4": "Found the order for 123-45-6789: it ships tomorrow.",

    "widget.title": "Or drop it straight on your site",
    "widget.body":
      "Paste one script tag on your page and this exact bubble goes live: no backend to write, no build step. A handful of optional attributes set the color, greeting, and language, so every visitor gets answered in the site's own language from the first message.",
    "widget.cta": "See the widget docs →",

    "usecases.title": "What people build with Pepe",
    "usecases.sub": "Common jobs once the right tools are connected.",
    "uc.social.t": "Social media management",
    "uc.social.d": "Schedule posts, answer comments, and track mentions across platforms.",
    "uc.email.t": "Inbox triage",
    "uc.email.d": "Read your inbox, draft replies, and file messages by topic.",
    "uc.ads.t": "Ad campaign ops",
    "uc.ads.d": "Watch spend and performance across Meta, Google, and LinkedIn Ads, then report daily.",
    "uc.support.t": "Customer support",
    "uc.support.d": "Answer people on WhatsApp, Slack, or Telegram, with human handoff when it matters.",
    "uc.sched.t": "Scheduling & reminders",
    "uc.sched.d": "Recurring tasks and one-shot watches that notify you when something changes.",
    "uc.reports.t": "Reports & analytics",
    "uc.reports.d": "Pull numbers from your own tools and ship a summary on a schedule.",
    "uc.monitor.t": "Error monitoring",
    "uc.monitor.d": "Watch Sentry, AppSignal, and other monitoring tools, then surface what actually needs a human.",
    "uc.insights.t": "Database insights",
    "uc.insights.d": "Query your database and turn raw numbers into useful next steps.",
    "uc.notes.t": "Meeting notes & recaps",
    "uc.notes.d": "Turn a transcript into a summary and action items, delivered where the team already talks.",

    "how.title": "Inside a single turn",
    "how.sub":
      "Zooming into the turn loop: Pepe calls the model, runs the tool calls it asks for, feeds the results back, and stops when the answer is ready.",
    "how.1.t": "Call the model",
    "how.1.d": "Send the conversation and the agent's tool specs to the model (with failover).",
    "how.2.t": "Run tool calls",
    "how.2.d": "Execute what the model asked for. Shell, files, web. Through the permission gate.",
    "how.3.t": "Feed results back",
    "how.3.d": "Append each tool result to the conversation and call the model again.",
    "how.4.t": "Answer & deliver",
    "how.4.d": "Return the final reply on the surface that asked, then record the run as a trace.",

    "cta.title": "Run your own agents in minutes",
    "cta.sub": "Open source. Bring your model. Keep the runtime, keys, and data under your control.",
    "cta.start": "Quickstart",
    "cta.github": "Star on GitHub",
    "why.title": "Why \"Pepe\"?",
    "why.body": "The name nods to Chespirito's comedy universe, loved across Latin America. Pepe's joke was simple: he did exactly what he was told. No debate, no freelancing. That is a pretty good brief for an agent runtime.",

    "foot.tagline":
      "An Elixir/OTP AI agent runtime. Self-hosted, model-agnostic, no database. Not affiliated with any model provider.",
    "foot.docs": "Docs",
    "foot.guides": "Guides",
    "foot.project": "Project",
    "foot.terms": "Terms",
    "foot.privacy": "Privacy",
    "foot.intro": "Introduction",
    "foot.quickstart": "Quickstart",
    "foot.agents": "Agents & tools",
    "foot.channels": "Channels",
    "foot.plugins": "Plugins",
    "foot.scheduled": "Scheduled tasks",
    "foot.security": "Security & sandbox",
    "foot.api": "HTTP API",
    "foot.documentation": "Documentation",
  },

  es: {
    "seo.title": "Pepe, el runtime de agentes de IA que ejecutas tú mismo",
    "nav.features": "Características",
    "nav.surfaces": "Superficies",
    "nav.channels": "Canales",
    "nav.security": "Seguridad",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · autoalojado",
    "hero.title": 'El runtime de agentes IA<br/>que <span class="grad">ejecutas tú mismo</span>.',
    "hero.lead":
      "Monta un equipo de empleados virtuales que gestiona tu correo, atiende a tus clientes, analiza los datos de tu sitio y lleva tus campañas en Google y Meta: prácticamente todo lo que harías tú mismo. Corre en tu propio servidor, con tus propias claves, bajo tu control.",
    "hero.cta_start": "Empezar →",
    "hero.cta_docs": "Leer la documentación",

    "loops.code_task": "limpiar la lista de clientes",
    "loops.code_crit": "sin correos duplicados, cada fila con un teléfono válido",
    "loops.code_prompt": "# un prompt te da una respuesta, y tú la calificas",
    "loops.code_goal": "# un objetivo sigue hasta que un revisor confirma que está hecho",
    "loops.title": 'Deja de dar órdenes. <span class="grad">Define el resultado.</span>',
    "loops.sub":
      "Un prompt te da un turno: el agente responde y tú decides si está bien. Eso te convierte en el cuello de botella, aprobador e inspector de calidad a la vez, y el trabajo solo avanza mientras estás frente al teclado. Dale un objetivo: di qué significa \"terminado\", y Pepe sigue trabajando hasta que un revisor independiente confirme que se cumplió.",
    "loop.turn.t": "Bucle de turno",
    "loop.turn.d":
      "Llama herramientas, lee los resultados, llama más. Para cuando tiene una respuesta real, no una suposición.",
    "loop.goal.t": "Bucle de objetivo",
    "loop.goal.d":
      "Defines el objetivo y qué cuenta como hecho. Quien juzga es un revisor independiente, no el agente. ¿Aún no? Recibe el comentario y reintenta.",
    "loop.time.t": "Bucle de tiempo",
    "loop.time.d":
      "Trabajo recurrente programado. Se ejecuta solo y recupera lo que se perdió mientras estuvo apagado.",

    "surfaces.title": "Un agente, cuatro superficies",
    "surfaces.sub":
      "Define un agente una vez. Úsalo desde la superficie que encaje con la tarea, con las mismas herramientas y memoria.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "Ejecuciones puntuales y un REPL interactivo.",
    "surf.http.t": "API HTTP",
    "surf.http.d":
      "Compatible con OpenAI: <code>/chat/completions</code> y <code>/models</code>, desde cualquier SDK.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "Una conexión WebSocket para conversaciones en vivo por streaming.",
    "surf.ch.t": "Canales",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "Lo esencial para ejecutar agentes",
    "features.sub":
      "Modelos, herramientas, automatización, plugins y control en un runtime pequeño y autoalojado.",
    "features.enlarge": "Ampliar imagen",
    "f.model.t": "Cualquier modelo, con failover",
    "f.model.d":
      "Conecta cualquier endpoint compatible con OpenAI. Define una cadena de respaldo que avanza ante errores transitorios.",
    "f.routing.t": "Enrutamiento por complejidad",
    "f.routing.d":
      "Una llamada de clasificación barata evalúa cada conversación nueva. Las preguntas simples bajan de forma automática a un modelo más ligero; toda la potencia queda para lo que de verdad la necesita.",
    "f.goal.t": "Objetivos, no solo prompts",
    "f.goal.d":
      "Da un objetivo y qué cuenta como hecho. Un revisor independiente decide si se cumplió, y el agente reintenta con ese comentario hasta pasar o agotar tu límite de intentos.",
    "f.tools.t": "Bucle real de herramientas",
    "f.tools.d":
      "Herramientas integradas para shell, archivos, web, scripts y envío de archivos. Añade las tuyas en minutos.",
    "f.channels.t": "Canales de mensajería",
    "f.channels.d":
      "Vincula un agente a Telegram o a canales por webhook, con traspaso, modos admin/soporte y alcance por conexión.",
    "f.cron.t": "Tareas programadas",
    "f.cron.d":
      "Cron con zona horaria dentro de Pepe. Los agentes pueden proponer tareas desde el chat, con tu aprobación.",
    "f.plugins.t": "Plugins en tiempo de ejecución",
    "f.plugins.d":
      "Instala un plugin, completa su configuración y da a los agentes nuevas herramientas o canales al instante.",
    "f.learn.t": "Aprendizaje y memoria",
    "f.learn.d":
      "El agente recuerda lo que aprende (hechos, preferencias, las personas con las que trata) y lo reutiliza en conversaciones posteriores. Lee y edita cualquier memoria desde el panel.",
    "f.usage.t": "Límites de gasto y mensajes",
    "f.usage.d":
      "Limita cada empresa por gasto y por mensajes: un presupuesto mensual en dólares y un límite mensual de mensajes. Ambos medidos en vivo, poniéndose en rojo en el panel a medida que se agotan.",
    "f.sandbox.t": "Control y seguridad",
    "f.sandbox.d": "Las herramientas riesgosas piden aprobación primero. Cada ejecución queda trazada, con las protecciones de comandos siempre activas.",
    "f.tenant.t": "Multiempresa",
    "f.tenant.d":
      "Las empresas opcionales aíslan agentes, modelos, canales y automatizaciones, con un tope de gasto y un tope de mensajes por empresa que puedes reiniciar cuando quieras.",
    "f.traces.t": "Trazas y uso",
    "f.traces.d":
      "Cada ejecución registra disparador, herramientas, tokens y coste. Abre una traza para reproducirla paso a paso.",
    "f.support.t": "Atención al cliente completa",
    "f.support.d":
      "Atiende clientes en WhatsApp, Telegram, Slack o Chatwoot, con traspaso humano cuando haga falta.",

    "channels.title": "Conecta con las personas donde estén",
    "channels.sub":
      "Conecta un canal y el agente responde allí. Archivos, traspaso y alcance vienen incluidos.",

    "security.title": "Privacidad por diseño",
    "security.sub":
      "Los datos sensibles nunca se envían en claro a un modelo externo, lo que te ayuda a cumplir exigencias como la LGPD, el GDPR y la HIPAA.",
    "security.1.t": "Lo que envía el usuario",
    "security.1.d": "El mensaje tal como lo escribió.",
    "security.2.t": "Lo que llega al modelo",
    "security.2.d": "Pepe cambia el dato sensible por un token antes de que la petición salga de tu servidor.",
    "security.3.t": "Lo que responde el modelo",
    "security.3.d": "Razona sobre el token. Nunca vio el valor real, ni lo guardó.",
    "security.4.t": "Lo que recibe el usuario",
    "security.4.d": "Pepe repone el valor real, solo de tu lado.",
    "security.chip.1": "Mi DNI es 12345678A, ¿puedes ver mi pedido?",
    "security.chip.2": "Mi DNI es [DNI_1], ¿puedes ver mi pedido?",
    "security.chip.3": "Encontré el pedido de [DNI_1]: sale mañana.",
    "security.chip.4": "Encontré el pedido de 12345678A: sale mañana.",

    "widget.title": "O colócalo directo en tu sitio",
    "widget.body":
      "Pega una sola etiqueta script en tu página y esta misma burbuja queda activa, sin backend que programar, sin paso de compilación. Unos pocos atributos opcionales definen el color, el saludo y el idioma, así cada visitante recibe respuesta en el idioma propio del sitio desde el primer mensaje.",
    "widget.cta": "Ver la documentación del widget →",

    "usecases.title": "Qué construye la gente con Pepe",
    "usecases.sub": "Trabajos habituales cuando conectas las herramientas adecuadas.",
    "uc.social.t": "Gestión de redes sociales",
    "uc.social.d": "Programa publicaciones, responde comentarios y sigue menciones en todas las plataformas.",
    "uc.email.t": "Priorización de correo",
    "uc.email.d": "Lee tu bandeja, redacta respuestas y archiva mensajes por tema.",
    "uc.ads.t": "Campañas publicitarias",
    "uc.ads.d": "Vigila el gasto y el rendimiento en Meta, Google y LinkedIn Ads, y reporta a diario.",
    "uc.support.t": "Atención al cliente",
    "uc.support.d": "Responde a la gente en WhatsApp, Slack o Telegram, con traspaso humano cuando importa.",
    "uc.sched.t": "Programación y avisos",
    "uc.sched.d": "Tareas recurrentes y avisos puntuales cuando algo cambia.",
    "uc.reports.t": "Informes y analítica",
    "uc.reports.d": "Extrae números de tus propias herramientas y envía un resumen en un horario.",
    "uc.monitor.t": "Monitoreo de errores",
    "uc.monitor.d": "Vigila Sentry, AppSignal y otras herramientas de monitoreo, y señala lo que de verdad necesita atención humana.",
    "uc.insights.t": "Análisis de datos",
    "uc.insights.d": "Consulta tu base de datos y convierte números en próximos pasos.",
    "uc.notes.t": "Notas y resúmenes de reuniones",
    "uc.notes.d": "Convierte una transcripción en un resumen y tareas, entregado donde tu equipo ya conversa.",

    "how.title": "Dentro de un solo turno",
    "how.sub":
      "Una ampliación del bucle de turno: Pepe llama al modelo, ejecuta las herramientas que pide, devuelve los resultados y se detiene cuando la respuesta está lista.",
    "how.1.t": "Llamar al modelo",
    "how.1.d": "Envía la conversación y las herramientas del agente al modelo (con failover).",
    "how.2.t": "Ejecutar herramientas",
    "how.2.d": "Ejecuta lo que pidió el modelo. Shell, archivos, web. Tras la aprobación.",
    "how.3.t": "Devolver resultados",
    "how.3.d": "Añade cada resultado a la conversación y vuelve a llamar al modelo.",
    "how.4.t": "Responder y entregar",
    "how.4.d": "Devuelve la respuesta final donde se pidió y registra la ejecución como traza.",

    "cta.title": "Ejecuta tus propios agentes en minutos",
    "cta.sub": "Código abierto. Trae tu modelo. Mantén runtime, claves y datos bajo tu control.",
    "cta.start": "Inicio rápido",
    "cta.github": "Estrella en GitHub",
    "why.title": "¿Por qué \"Pepe\"?",
    "why.body": "El nombre guiña un ojo al universo de Chespirito, querido en toda América Latina. El chiste de Pepe era simple: hacía exactamente lo que le pedían. Sin discutir ni improvisar. Una buena descripción para un runtime de agentes.",

    "foot.tagline":
      "Un runtime de agentes IA en Elixir/OTP. Autoalojado, agnóstico de modelo, sin base de datos. Sin afiliación con ningún proveedor de modelos.",
    "foot.docs": "Docs",
    "foot.guides": "Guías",
    "foot.project": "Proyecto",
    "foot.terms": "Términos",
    "foot.privacy": "Privacidad",
    "foot.intro": "Introducción",
    "foot.quickstart": "Inicio rápido",
    "foot.agents": "Agentes y herramientas",
    "foot.channels": "Canales",
    "foot.plugins": "Plugins",
    "foot.scheduled": "Tareas programadas",
    "foot.security": "Seguridad y sandbox",
    "foot.api": "API HTTP",
    "foot.documentation": "Documentación",
  },

  "pt-br": {
    "seo.title": "Pepe, o runtime de agentes de IA que você mesmo executa",
    "nav.features": "Recursos",
    "nav.surfaces": "Superfícies",
    "nav.channels": "Canais",
    "nav.security": "Segurança",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · auto-hospedado",
    "hero.title": 'O runtime de agentes de IA<br/>que <span class="grad">você mesmo executa</span>.',
    "hero.lead":
      "Monte uma equipe de funcionários virtuais que cuida do e-mail, atende clientes, analisa os dados do seu site e toca campanhas no Google e no Meta: praticamente tudo que você faria. Fica no seu servidor, com suas chaves, sob seu controle.",
    "hero.cta_start": "Começar →",
    "hero.cta_docs": "Ler a documentação",

    "loops.code_task": "limpar a lista de clientes",
    "loops.code_crit": "sem e-mails duplicados, toda linha com telefone válido",
    "loops.code_prompt": "# um prompt te dá uma resposta, e você que julga",
    "loops.code_goal": "# um objetivo insiste até um revisor dizer que está pronto",
    "loops.title": 'Pare de dar ordens. <span class="grad">Defina o resultado.</span>',
    "loops.sub":
      "Um prompt te dá um turno: o agente responde e você decide se ficou bom. Isso te transforma no gargalo, aprovador e inspetor de qualidade ao mesmo tempo, e o trabalho só anda enquanto você está na frente do teclado. Dê um objetivo: diga o que significa \"pronto\", e o Pepe continua trabalhando até um revisor independente concordar que chegou lá.",
    "loop.turn.t": "Loop de turno",
    "loop.turn.d":
      "Chama ferramentas, lê os resultados, chama mais. Para quando tem uma resposta de verdade, não um chute.",
    "loop.goal.t": "Loop de objetivo",
    "loop.goal.d":
      "Você define o objetivo e o que conta como pronto. Quem julga é um revisor independente, não o agente. Não chegou? Ele recebe o retorno e tenta de novo.",
    "loop.time.t": "Loop de tempo",
    "loop.time.d":
      "Trabalho recorrente, no horário que você marcar. Roda sozinho e recupera o que perdeu enquanto esteve fora.",

    "surfaces.title": "Um agente, quatro superfícies",
    "surfaces.sub":
      "Defina um agente uma vez. Use pela superfície certa para a tarefa, com as mesmas ferramentas e memória.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "Execuções pontuais e um REPL interativo.",
    "surf.http.t": "API HTTP",
    "surf.http.d":
      "Compatível com a OpenAI: <code>/chat/completions</code> e <code>/models</code>, de qualquer SDK.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "Uma conexão WebSocket para conversas ao vivo com streaming.",
    "surf.ch.t": "Canais",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "O essencial para rodar agentes",
    "features.sub":
      "Modelos, ferramentas, automação, plugins e controle em um runtime pequeno e auto-hospedado.",
    "features.enlarge": "Ampliar imagem",
    "f.model.t": "Qualquer modelo, com failover",
    "f.model.d":
      "Conecte qualquer endpoint compatível com OpenAI. Defina uma cadeia de fallback que avança em erros transitórios.",
    "f.routing.t": "Roteamento por complexidade",
    "f.routing.d":
      "Uma chamada de classificação barata avalia cada conversa nova. Pergunta simples desce sozinha pra um modelo mais leve; a força total fica reservada pro que realmente precisa dela.",
    "f.goal.t": "Objetivos, não só prompts",
    "f.goal.d":
      "Dê um objetivo e o que conta como pronto. Um revisor independente decide se foi atingido, e o agente tenta de novo com esse retorno até passar ou bater o seu limite de tentativas.",
    "f.tools.t": "Loop real de ferramentas",
    "f.tools.d":
      "Ferramentas nativas para shell, arquivos, web, scripts e envio de arquivos. Adicione as suas em minutos.",
    "f.channels.t": "Canais de mensagem",
    "f.channels.d":
      "Vincule um agente ao Telegram ou a canais por webhook, com handoff, modos admin/suporte e escopo por conexão.",
    "f.cron.t": "Tarefas agendadas",
    "f.cron.d":
      "Cron com fuso horário dentro do Pepe. Agentes podem propor tarefas pelo chat, com a sua aprovação.",
    "f.plugins.t": "Plugins em runtime",
    "f.plugins.d":
      "Instale um plugin, preencha a configuração e dê aos agentes novas ferramentas ou canais na hora.",
    "f.learn.t": "Aprendizado e memória",
    "f.learn.d":
      "O agente lembra o que aprende (fatos, preferências, as pessoas com quem fala) e reaproveita nas próximas conversas. Leia e edite qualquer memória pelo painel.",
    "f.usage.t": "Limites de gasto e mensagens",
    "f.usage.d":
      "Limite cada empresa por gasto e por mensagens: um orçamento mensal em dólar e um limite mensal de mensagens. Ambos medidos ao vivo, ficando vermelhos no painel conforme se esgotam.",
    "f.sandbox.t": "Controle e segurança",
    "f.sandbox.d": "Ferramentas arriscadas pedem aprovação antes. Toda execução fica rastreada, com proteções de comando sempre ligadas.",
    "f.tenant.t": "Multiempresa",
    "f.tenant.d":
      "Empresas opcionais isolam agentes, modelos, canais e automações, com um teto de gasto e um teto de mensagens por empresa que você pode resetar quando quiser.",
    "f.traces.t": "Traces e uso",
    "f.traces.d":
      "Cada execução registra gatilho, ferramentas, tokens e custo. Abra um trace para rever passo a passo.",
    "f.support.t": "Atendimento ao cliente completo",
    "f.support.d":
      "Atenda clientes no WhatsApp, Telegram, Slack ou Chatwoot, com handoff humano quando precisar.",

    "channels.title": "Conecte-se com as pessoas onde elas estiverem",
    "channels.sub":
      "Conecte um canal e o agente responde por lá. Arquivos, handoff e escopo vêm prontos.",

    "security.title": "Privacidade desde o design",
    "security.sub":
      "Dado sensível nunca é enviado em claro pra um modelo externo, o que ajuda a atender exigências como LGPD, GDPR e HIPAA.",
    "security.1.t": "O que o usuário envia",
    "security.1.d": "A mensagem exatamente como ele digitou.",
    "security.2.t": "O que chega no modelo",
    "security.2.d": "O Pepe troca o dado sensível por um token antes de a requisição sair do seu servidor.",
    "security.3.t": "O que o modelo responde",
    "security.3.d": "Ele raciocina sobre o token. Nunca viu o valor real, e nunca o guardou.",
    "security.4.t": "O que o usuário recebe",
    "security.4.d": "O Pepe repõe o valor real, só do seu lado.",
    "security.chip.1": "Meu CPF é 123.456.789-00, pode ver meu pedido?",
    "security.chip.2": "Meu CPF é [CPF_1], pode ver meu pedido?",
    "security.chip.3": "Achei o pedido do [CPF_1]: sai para entrega amanhã.",
    "security.chip.4": "Achei o pedido do 123.456.789-00: sai para entrega amanhã.",

    "widget.title": "Ou coloque direto no seu site",
    "widget.body":
      "Cole uma única tag script na sua página e essa mesma bolha já fica no ar, sem backend pra escrever, sem passo de build. Alguns atributos opcionais definem a cor, a saudação e o idioma, então cada visitante é respondido no idioma do próprio site já na primeira mensagem.",
    "widget.cta": "Ver a documentação do widget →",

    "usecases.title": "O que as pessoas constroem com o Pepe",
    "usecases.sub": "Trabalhos comuns quando você conecta as ferramentas certas.",
    "uc.social.t": "Gestão de redes sociais",
    "uc.social.d": "Agende posts, responda comentários e acompanhe menções em todas as plataformas.",
    "uc.email.t": "Priorização de e-mail",
    "uc.email.d": "Leia sua caixa de entrada, rascunhe respostas e organize mensagens por assunto.",
    "uc.ads.t": "Campanhas de anúncios",
    "uc.ads.d": "Acompanhe gasto e desempenho no Meta, Google e LinkedIn Ads, com relatório diário.",
    "uc.support.t": "Atendimento ao cliente",
    "uc.support.d": "Responda no WhatsApp, Slack ou Telegram, com handoff humano quando importa.",
    "uc.sched.t": "Agendamento e lembretes",
    "uc.sched.d": "Tarefas recorrentes e avisos pontuais quando algo muda.",
    "uc.reports.t": "Relatórios e análises",
    "uc.reports.d": "Puxe números das suas próprias ferramentas e envie um resumo periodicamente.",
    "uc.monitor.t": "Monitoramento de erros",
    "uc.monitor.d": "Acompanhe Sentry, AppSignal e outras ferramentas de observabilidade, e aponte o que realmente precisa de atenção humana.",
    "uc.insights.t": "Insights de dados",
    "uc.insights.d": "Consulte seu banco de dados e transforme números em próximos passos.",
    "uc.notes.t": "Notas e resumos de reuniões",
    "uc.notes.d": "Transforme uma transcrição em resumo e itens de ação, entregues onde o time já conversa.",

    "how.title": "Por dentro de um turno",
    "how.sub":
      "Um zoom no loop de turno: o Pepe chama o modelo, executa as ferramentas que ele pedir, devolve os resultados e para quando a resposta está pronta.",
    "how.1.t": "Chamar o modelo",
    "how.1.d": "Envia a conversa e as ferramentas do agente ao modelo (com failover).",
    "how.2.t": "Rodar ferramentas",
    "how.2.d": "Executa o que o modelo pediu. Shell, arquivos, web. Após a aprovação.",
    "how.3.t": "Devolver resultados",
    "how.3.d": "Anexa cada resultado à conversa e chama o modelo de novo.",
    "how.4.t": "Responder e entregar",
    "how.4.d": "Devolve a resposta final onde ela foi pedida e registra a execução como trace.",

    "cta.title": "Execute seus próprios agentes em minutos",
    "cta.sub": "Código aberto. Traga seu modelo. Mantenha runtime, chaves e dados sob seu controle.",
    "cta.start": "Início rápido",
    "cta.github": "Dar estrela no GitHub",
    "why.title": "Por que \"Pepe\"?",
    "why.body": "O nome é uma referência ao universo do Chespirito, querido em toda a América Latina. A piada do Pepe era simples: ele fazia exatamente o que mandavam. Sem discutir, sem inventar moda. Um bom resumo para um runtime de agentes.",

    "foot.tagline":
      "Um runtime de agentes de IA em Elixir/OTP. Auto-hospedado, agnóstico de modelo, sem banco de dados. Sem afiliação a qualquer fornecedor de modelos.",
    "foot.docs": "Docs",
    "foot.guides": "Guias",
    "foot.project": "Projeto",
    "foot.terms": "Termos",
    "foot.privacy": "Privacidade",
    "foot.intro": "Introdução",
    "foot.quickstart": "Início rápido",
    "foot.agents": "Agentes e ferramentas",
    "foot.channels": "Canais",
    "foot.plugins": "Plugins",
    "foot.scheduled": "Tarefas agendadas",
    "foot.security": "Segurança e sandbox",
    "foot.api": "API HTTP",
    "foot.documentation": "Documentação",
  },

  "pt-pt": {
    "seo.title": "Pepe, o runtime de agentes de IA que executas tu próprio",
    "nav.features": "Funcionalidades",
    "nav.surfaces": "Superfícies",
    "nav.channels": "Canais",
    "nav.security": "Segurança",
    "nav.docs": "Docs",

    "hero.eyebrow": "Elixir / OTP · auto-alojado",
    "hero.title": 'O runtime de agentes de IA<br/>que <span class="grad">executas tu próprio</span>.',
    "hero.lead":
      "Monta uma equipa de funcionários virtuais que trata do teu email, atende clientes, analisa os dados do teu site e gere campanhas no Google e no Meta: praticamente tudo o que tu farias. Corre no teu próprio servidor, com as tuas chaves, sob o teu controlo.",
    "hero.cta_start": "Começar →",
    "hero.cta_docs": "Ler a documentação",

    "loops.code_task": "limpar a lista de clientes",
    "loops.code_crit": "sem e-mails duplicados, todas as linhas com telefone válido",
    "loops.code_prompt": "# um prompt dá-lhe uma resposta, e é você que a julga",
    "loops.code_goal": "# um objetivo insiste até um revisor dizer que está concluído",
    "loops.title": 'Pare de dar ordens. <span class="grad">Defina o resultado.</span>',
    "loops.sub":
      "Um prompt dá-lhe um turno: o agente responde e é você que decide se está bom. Isso torna-o no estrangulamento, aprovador e inspetor de qualidade ao mesmo tempo, e o trabalho só avança enquanto está à frente do teclado. Dê antes um objetivo: diga o que significa \"concluído\", e o Pepe continua a trabalhar até um revisor independente concordar que foi atingido.",
    "loop.turn.t": "Ciclo de turno",
    "loop.turn.d":
      "Chama ferramentas, lê os resultados, chama mais. Para quando tem uma resposta a sério, não um palpite.",
    "loop.goal.t": "Ciclo de objetivo",
    "loop.goal.d":
      "Define o objetivo e o que conta como concluído. Quem avalia é um revisor independente, não o agente. Ainda não? Recebe o retorno e tenta de novo.",
    "loop.time.t": "Ciclo de tempo",
    "loop.time.d":
      "Trabalho recorrente agendado. Corre sozinho e recupera o que falhou enquanto esteve desligado.",

    "surfaces.title": "Um agente, quatro superfícies",
    "surfaces.sub":
      "Define um agente uma vez. Usa-o pela superfície certa para a tarefa, com as mesmas ferramentas e memória.",
    "surf.cli.t": "CLI",
    "surf.cli.d": "Execuções pontuais e um REPL interativo.",
    "surf.http.t": "API HTTP",
    "surf.http.d":
      "Compatível com a OpenAI: <code>/chat/completions</code> e <code>/models</code>, a partir de qualquer SDK.",
    "surf.ws.t": "WebSocket",
    "surf.ws.d": "Uma ligação WebSocket para conversas ao vivo com streaming.",
    "surf.ch.t": "Canais",
    "surf.ch.d": "Telegram, WhatsApp, Slack, Discord, Teams, Google Chat.",

    "features.title": "O essencial para correr agentes",
    "features.sub":
      "Modelos, ferramentas, automação, plugins e controlo num runtime pequeno e auto-alojado.",
    "features.enlarge": "Ampliar imagem",
    "f.model.t": "Qualquer modelo, com failover",
    "f.model.d":
      "Liga qualquer endpoint compatível com OpenAI. Define uma cadeia de recurso que avança em erros transitórios.",
    "f.routing.t": "Encaminhamento por complexidade",
    "f.routing.d":
      "Uma chamada de classificação barata avalia cada conversa nova. Perguntas simples descem sozinhas para um modelo mais leve; a força toda fica reservada para o que precisa mesmo dela.",
    "f.goal.t": "Objetivos, não apenas prompts",
    "f.goal.d":
      "Dê um objetivo e o que conta como concluído. Um revisor independente decide se foi cumprido, e o agente tenta de novo com esse retorno até passar ou atingir o seu limite de tentativas.",
    "f.tools.t": "Ciclo real de ferramentas",
    "f.tools.d":
      "Ferramentas nativas para shell, ficheiros, web, scripts e envio de ficheiros. Adiciona as tuas em minutos.",
    "f.channels.t": "Canais de mensagens",
    "f.channels.d":
      "Liga um agente ao Telegram ou a canais por webhook, com transferência, modos admin/suporte e âmbito por ligação.",
    "f.cron.t": "Tarefas agendadas",
    "f.cron.d":
      "Cron com fuso horário dentro do Pepe. Os agentes podem propor tarefas pelo chat, com a tua aprovação.",
    "f.plugins.t": "Plugins em tempo de execução",
    "f.plugins.d":
      "Instala um plugin, preenche a configuração e dá aos agentes novas ferramentas ou canais de imediato.",
    "f.learn.t": "Aprendizagem e memória",
    "f.learn.d":
      "O agente lembra o que aprende (factos, preferências, as pessoas com quem fala) e reaproveita nas conversas seguintes. Leia e edite qualquer memória pelo painel.",
    "f.usage.t": "Limites de gasto e mensagens",
    "f.usage.d":
      "Limite cada empresa por gasto e por mensagens: um orçamento mensal em dólar e um limite mensal de mensagens. Ambos medidos ao vivo, ficando vermelhos no painel à medida que se esgotam.",
    "f.sandbox.t": "Controlo e segurança",
    "f.sandbox.d": "Ferramentas arriscadas pedem aprovação antes. Toda execução fica rastreada, com proteções de comando sempre ligadas.",
    "f.tenant.t": "Multiempresa",
    "f.tenant.d":
      "Empresas opcionais isolam agentes, modelos, canais e automações, com um limite de despesa e um limite de mensagens por empresa que pode repor quando quiser.",
    "f.traces.t": "Traces e utilização",
    "f.traces.d":
      "Cada execução regista o gatilho, ferramentas, tokens e custo. Abre um trace para rever passo a passo.",
    "f.support.t": "Apoio ao cliente completo",
    "f.support.d":
      "Atende clientes no WhatsApp, Telegram, Slack ou Chatwoot, com transferência humana quando for preciso.",

    "channels.title": "Liga-te às pessoas onde elas estiverem",
    "channels.sub":
      "Liga um canal e o agente responde por lá. Ficheiros, transferência e âmbito vêm prontos.",

    "security.title": "Privacidade desde a conceção",
    "security.sub":
      "Dados sensíveis nunca são enviados em claro para um modelo externo, o que ajuda a cumprir exigências como o RGPD, a LGPD e a HIPAA.",
    "security.1.t": "O que o utilizador envia",
    "security.1.d": "A mensagem tal como a escreveu.",
    "security.2.t": "O que chega ao modelo",
    "security.2.d": "O Pepe troca o dado sensível por um token antes de o pedido sair do seu servidor.",
    "security.3.t": "O que o modelo responde",
    "security.3.d": "Raciocina sobre o token. Nunca viu o valor real, nem o guardou.",
    "security.4.t": "O que o utilizador recebe",
    "security.4.d": "O Pepe repõe o valor real, apenas do seu lado.",
    "security.chip.1": "O meu NIF é 123 456 789, pode ver a minha encomenda?",
    "security.chip.2": "O meu NIF é [NIF_1], pode ver a minha encomenda?",
    "security.chip.3": "Encontrei a encomenda do [NIF_1]: sai para entrega amanhã.",
    "security.chip.4": "Encontrei a encomenda do 123 456 789: sai para entrega amanhã.",

    "widget.title": "Ou coloca-o direto no teu site",
    "widget.body":
      "Cola uma única tag script na tua página e esta mesma bolha fica logo ativa, sem backend para escrever, sem passo de build. Alguns atributos opcionais definem a cor, a saudação e o idioma, para que cada visitante seja respondido no idioma do próprio site já na primeira mensagem.",
    "widget.cta": "Ver a documentação do widget →",

    "usecases.title": "O que as pessoas constroem com o Pepe",
    "usecases.sub": "Trabalhos comuns quando ligas as ferramentas certas.",
    "uc.social.t": "Gestão de redes sociais",
    "uc.social.d": "Agenda publicações, responde a comentários e acompanha menções em todas as plataformas.",
    "uc.email.t": "Priorização de e-mail",
    "uc.email.d": "Lê a tua caixa de entrada, rascunha respostas e organiza mensagens por assunto.",
    "uc.ads.t": "Campanhas de anúncios",
    "uc.ads.d": "Acompanha o gasto e o desempenho no Meta, Google e LinkedIn Ads, com relatório diário.",
    "uc.support.t": "Apoio ao cliente",
    "uc.support.d": "Responde no WhatsApp, Slack ou Telegram, com transferência humana quando importa.",
    "uc.sched.t": "Agendamento e lembretes",
    "uc.sched.d": "Tarefas recorrentes e avisos pontuais quando algo muda.",
    "uc.reports.t": "Relatórios e análises",
    "uc.reports.d": "Extrai números das tuas próprias ferramentas e envia um resumo periodicamente.",
    "uc.monitor.t": "Monitorização de erros",
    "uc.monitor.d": "Acompanha o Sentry, o AppSignal e outras ferramentas de observabilidade, e aponta o que precisa mesmo de atenção humana.",
    "uc.insights.t": "Insights de dados",
    "uc.insights.d": "Consulta a tua base de dados e transforma números em próximos passos.",
    "uc.notes.t": "Notas e resumos de reuniões",
    "uc.notes.d": "Transforma uma transcrição em resumo e itens de ação, entregues onde a equipa já fala.",

    "how.title": "Por dentro de um turno",
    "how.sub":
      "Uma ampliação do ciclo de turno: o Pepe chama o modelo, executa as ferramentas que pedir, devolve os resultados e para quando a resposta está pronta.",
    "how.1.t": "Chamar o modelo",
    "how.1.d": "Envia a conversa e as ferramentas do agente ao modelo (com failover).",
    "how.2.t": "Correr ferramentas",
    "how.2.d": "Executa o que o modelo pediu. Shell, ficheiros, web. Após a aprovação.",
    "how.3.t": "Devolver resultados",
    "how.3.d": "Anexa cada resultado à conversa e chama o modelo de novo.",
    "how.4.t": "Responder e entregar",
    "how.4.d": "Devolve a resposta final onde ela foi pedida e regista a execução como trace.",

    "cta.title": "Executa os teus próprios agentes em minutos",
    "cta.sub": "Código aberto. Traz o teu modelo. Mantém runtime, chaves e dados sob teu controlo.",
    "cta.start": "Início rápido",
    "cta.github": "Dar estrela no GitHub",
    "why.title": "Porquê \"Pepe\"?",
    "why.body": "O nome pisca o olho ao universo de Chespirito, querido na América Latina. A piada do Pepe era simples: fazia exatamente o que lhe mandavam. Sem discutir nem inventar. Um bom resumo para um runtime de agentes.",

    "foot.tagline":
      "Um runtime de agentes de IA em Elixir/OTP. Auto-alojado, agnóstico de modelo, sem base de dados. Sem afiliação a qualquer fornecedor de modelos.",
    "foot.docs": "Docs",
    "foot.guides": "Guias",
    "foot.project": "Projeto",
    "foot.terms": "Termos",
    "foot.privacy": "Privacidade",
    "foot.intro": "Introdução",
    "foot.quickstart": "Início rápido",
    "foot.agents": "Agentes e ferramentas",
    "foot.channels": "Canais",
    "foot.plugins": "Plugins",
    "foot.scheduled": "Tarefas agendadas",
    "foot.security": "Segurança e sandbox",
    "foot.api": "API HTTP",
    "foot.documentation": "Documentação",
  },
} as const;

export function t(locale: Locale) {
  const dict = ui[locale] ?? ui[defaultLocale];
  return (key: keyof typeof ui["en"]) => (dict as Record<string, string>)[key] ?? key;
}
