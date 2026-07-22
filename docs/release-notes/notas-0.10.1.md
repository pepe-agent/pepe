# Notas da Versão — 0.10.1

Olá! Aqui estão as novidades, melhorias e correções de segurança desta atualização do Pepe.

---

## ✨ Novidades

### Browser tool — dirija o Chrome de verdade
Agora seu agent consegue abrir um navegador de verdade para acessar páginas que precisam de JavaScript, fazer login, ou navegar por fluxos multi-etapa. Uma sessão por conversa — as cookies e a página atual persistem de uma chamada para outra até você fechar ou ficar 10 minutos sem usar. As coisas da página (botões, inputs, links) ganham números que o agent usa para clicar sem ter que adivinhar seletores CSS.

O Pepe procura por Chrome/Chromium/Edge/Brave já instalado na máquina; se não achar, baixa um automaticamente e guarda na cache (desative com `PEPE_BROWSER_AUTO_DOWNLOAD=0` se preferir). Funciona out-of-the-box em Docker, em macOS e no Windows. No Linux ARM (Apple Silicon, hosts cloud com ARM64), busca da CDN do Playwright.

Mesmas proteções que `fetch_url` tem: só acessa `http://` e `https://`, bloqueia endereços internos (`localhost`, redes privadas). E é gated como `bash`, não sempre-permitido.

📍 *Onde usar: Chat ou dashboard, coloque a ferramenta `browser` no agent*

### memory_search — procure na sua própria memória
Seu agent agora consegue procurar na própria memória (`MEMORY.md`, `USER.md`, `people.md`) sem ter que ler o arquivo inteiro. Busca case-insensitive simples — rápido e direto, sem embeddings, porque a memória é mantida pequena de propósito (a revisão de consolidação faz seu trabalho).

Sempre seguro, e só acessa a memória do agent que está chamando.

📍 *Onde usar: qualquer agent que tem memória pode usar*

### session_search — ache conversas passadas
Agora existe uma ferramenta para procurar e ler conversas passadas — não desaparece mais quando a sessão acaba ou o Pepe reinicia. Ações disponíveis: listar sessões, procurar por conteúdo, ver o histórico completo de uma conversa, mostrar um turno específico.

Sempre seguro, e cada agent só vê suas próprias conversas (não as de outros agents da mesma companhia/projeto).

📍 *Onde usar: Chat ou dashboard, coloque a ferramenta `session_search` no agent*

### mix pepe flow — promova uma sequência comprovada em script
Quando seu agent faz a mesma sequência de tool calls duas ou mais vezes (como "validar os dados, salvar no banco, enviar email"), você pode promover isso para um script que roda sem chamar o modelo. Útil para automações repetitivas ou agendadas.

`mix pepe flow promote NOME` propõe o script; `mix pepe flow run NOME` executa sob demanda; `mix pepe flow schedule ...` agenda para rodar sozinho (cron). Um flow só roda passos que já passaram no `auto_approve` do agent, então não precisa de aprovação humana no meio.

📍 *Onde usar: CLI — `mix pepe flow --help`*

### Visualize o prompt completo do seu agent
`mix pepe agent prompt NOME` agora mostra exatamente o que o modelo vê como system prompt — não só o `system_prompt` field, mas tudo (persona, contrato comportamental, data/hora, índice de skills/docs, tudo que Pepe monta). Tem um "Assembled prompt" no dashboard também.

Útil para debugar comportamentos inesperados ou entender o que seu agent sabe de verdade.

📍 *Onde usar: CLI (`mix pepe agent prompt NOME`) ou dashboard na página do agent*

### fetch_url agora extrai o texto legível
`fetch_url` costumava devolver o HTML bruto com navbars, banners de cookie e anúncios inclusos. Agora retorna o texto legível da página por padrão — pula elementos conhecidos como ruído, prefere a `<article>` ou `<main>`, e cai para inteligência de scoring se nada disso existir.

Se você precisa do HTML literal (uma resposta JSON, código-fonte), use `raw: true`. Pages que não têm nada extraível voltam pro bruto automaticamente.

📍 *Onde usar: automaticamente em `fetch_url`, sem ação*

### mix pepe browser install — use o Chrome do sistema
No Linux, em vez de sempre baixar Chrome, `mix pepe browser install` detecta seu gerenciador de pacotes (apt/dnf/pacman/brew) e instala um de verdade na máquina — pede `sudo` quando necessário. Uma vez instalado, `browser` usa direto sem fazer nenhum download.

Só vale no Linux; no macOS e Windows, o Pepe já faz o certo (não precisa).

📍 *Onde usar: CLI — `mix pepe browser install`*

### Compromissos (commitments) — rastreie lembretes e promessas
Novidade opt-in (desligada por padrão): quando alguém pede "me avise em uma semana" ou o agent promete "vou verificar isso amanhã", o Pepe nota automaticamente no final do turno e rastreia.

Um lembrete do usuário entrega uma mensagem pronta quando vence. Uma promessa do agent re-executa a sessão, então o trabalho acontece de verdade antes de dizer que está feito.

Gerencie da conversa com a ferramenta `commitment`, ou da nova página **Commitments** no dashboard.

📍 *Onde usar: dashboard na página **Commitments**, ou chat com `commitment` tool*

### ask_user — faça perguntas de verdade
Nova ferramenta `ask_user` para fazer uma pergunta de múltipla escolha de verdade — botões tocáveis no Telegram, menu com setas no console, picker no dashboard. Bloqueia e retorna a resposta no mesmo turno, não encerra a conversa esperando que a próxima mensagem acerte.

Nunca é gated (perguntar não tem risco), mas só funciona onde tem uma pessoa interativa — falha na hora em um webhook ou cron.

📍 *Onde usar: agents que precisam de uma resposta concreta do usuário*

### delegate com background: true — dispare e deixe rodar
`delegate` agora aceita `background: true` para disparar um trabalho sem esperar — retorna uma mensagem no ato e os resultados chegam depois como follow-up, em vez de bloquear a conversa por até 3 minutos.

📍 *Onde usar: quando você quer delegação assíncrona*

### Telegram: polls e quick_reactions
- Nova ferramenta `telegram_poll` posta uma enquete de verdade no Telegram (inclusive enquetes quiz).
- Novo `quick_reactions`: uma mensagem que é só um "obrigado" ou um emoji recebe uma reação nativa em vez de uma resposta inteira (sem chamar o modelo).

📍 *Onde usar: Telegram — configure no agent ou use a ferramenta poll*

---

## 🚀 Melhorias

### Board card heartbeat — sinal de vida para trabalhos longos
Um card que estava realmente sendo trabalhado, passado seu `claim_timeout_s`, não tinha jeito de dizer "ei, ainda estou aqui" — podia ser bloqueado como travado mesmo estando vivo. Novo `board heartbeat` (e `mix pepe board card heartbeat ID`) reseta o relógio sem mudar status — puro sinal de vida, não progresso.

📍 *Onde usar: dashboard ou CLI*

### bash/run_script mais quieto para comandos seguros
Um `ls`, `cat`, `git status` ou `pytest` agora roda direto sem pedir aprovação — mesmo free pass que `read_file` já tinha, porque não tem risco. Comandos que mexem com arquivos, deletam coisas ou acessam rede ainda pedem como antes. Só muda em superfícies interativas (chat, dashboard); em webhook/cron/API sem humano, nada muda.

📍 *Onde usar: automaticamente*

### mix pepe update aponta para o changelog
Depois de atualizar, `mix pepe update` agora mostra onde procurar pelas mudanças (CHANGELOG.md e `mix pepe agent prompt NOME`). Útil porque o system prompt de cada agent mudou de verdade e não tem nada em `config.json` pra diffar.

📍 *Onde usar: automaticamente*

### Banco de dados migrado para SQLite
Commitments, config journal, watches, traces, boards e usage saíram de `config.json` e arquivos soltos para um banco de dados SQLite embedado (`~/.pepe/data/pepe.db`). Mais rápido, mais robusto, sem quebra em superfícies — as APIs públicas (`Pepe.Config.commitment_*`, etc) são as mesmas.

Agent/model/channel definitions ficam em `config.json` mesmo (editável, git-diffable, portável).

📍 *Onde usar: automático — nada pra fazer*

---

## 🐛 Correções de Segurança e Confiabilidade

### Browser: qualquer requisição agora é bloqueada se apontar pra dentro
O browser tinha uma proteção contra SSRF na URL inicial (`open`), mas links que a página clicava, redirecionamentos JS, form submits e fetch/XHR da página passavam despercebidos. Tudo agora passa por interception (CDP Fetch-domain), validado do mesmo jeito que `open` faz — se resolve para um endereço interno, falha antes de Chrome mandar nada.

### session_search: agora só vê a conversa própria por padrão
Se um agent serve vários clientes no mesmo projeto (um support bot), a busca de conversas passadas podia vazar o histórico de um cliente pro outro. Agora padrão é `"self"` — cada conversa só enxerga a si mesma. Um agent que de verdade não tem outro cliente pra vazar pode opt-in na configuração `session_search_scope` (checkbox no dashboard) pra ver o projeto inteiro.

### run_script em python/node/ruby agora pede aprovação
Python, Node.js e Ruby tinham o mesmo free pass que `bash` tem (sem risco aparente, roda direto), mas o analisador de risco só entende sintaxe shell — uma one-liner Python que deleta arquivos ou abre um socket rodava sem avisar. Agora só `bash`/`sh` têm o free pass. E o analisador shell ganhou detecção pra `find -delete`, `dd`, `mv`/`cp`/`chmod`, redirects relativos e piping em qualquer interpreter.

### send_to_agent preserva o contexto da conversa chamadora
`send_to_agent` roda um consult nested no mesmo processo do turno chamador — começar isso sem cuidado resetava o estado de taint e grants do turno. Agora tira um snapshot antes, roda o nested, e restaura depois.

### Invisível no meio do token não passa mais
Um `<|im_start|>` com um zero-width space (`<|im_start|>`) no meio escapava da sanitização de control tokens — os dois passes rodavam na ordem errada. Fixo.

### Flow.replay para em erros, não só em denials
Um passo que dava erro (arquivo faltando, rede caiu, argumentos ruins) deixava todos os passos depois rodarem mesmo assim, e o flow era reportado como "completo". Agora para no primeiro passo que falha, como já fazia com denials.

### Promoting a flow verifica limpeza
Promover um flow de traces podia bake in uma tool call que tinha sido negada ou falhado na fonte (o evento é gravado antes do outcome ser conhecido), ou comparar argumentos truncados vs os reais. Agora recusa qualquer trace que não está limpo: nenhuma call negada/falhada, e nenhuma truncada.

### Flow binding sobrevive a rename
Renomear um agent ou seu projeto nunca atualizava os flows que o agent tinha — um flow agendado quebrava pra sempre. Fixo (mesmo tipo de gap que já fechamos pra traces/usage/watches).

### Raw model connection (sem agent) não recebe system prompt de agent
Uma chamada `/v1/chat/completions` com só `model: <nome>` (sem agent) começou a receber o prompt completo do agent (contrato, docs, tudo) em vez do seed simples. Era um side-effect de uma correção de paridade de prompt que não contava com esse wrapper interno. Fixo.

### Browser ref tags stale não colidem com novos elementos
Uma tag `data-pepe-ref` velha de um snapshot anterior podia se choque com um elemento diferente no novo, então "clique ref 3" batia qualquer que fosse a coisa #3 agora na página. Todo snapshot agora limpa refs velhas antes de re-rotular.

### Browser Windows sempre baixava 32-bit
`:erlang.system_info(:system_architecture)` retorna a string literal `"win32"` no Windows mesmo com CPU 64-bit. Agora lê as variáveis de ambiente `PROCESSOR_ARCHITECTURE`/`PROCESSOR_ARCHITEW6432` do Windows mesmo.

### mix pepe browser install funciona no Ubuntu
`apt chromium` lá é um stub transitório sem candidato instalável (o real é o Debian). Tenta `chromium-browser` (o de verdade no Ubuntu) como fallback. Fixo.

### Timeouts/crashes do browser agora reportam claramente
Um `browser` call depois de um timeout ou crash real era mau-reportado como "sem sessão aberta" — mesma coisa que um close race normal. Agora diz claramente o que aconteceu.

### Telegram: 20MB+ de arquivo não desaparecem silenciosamente
Um arquivo do Telegram acima de 20MB (limit do bot) desaparecia sem reclamação. Agora nomeia a razão ("arquivo grande demais pro bot buscar"); e em um upload de vários arquivos, te diz quais não chegaram.

### Board heartbeat não quebra dead-worker detection
`board heartbeat` tava resetando `claimed_at`, a coluna que o scheduler usa pra detecção de worker travado (`block_if_still_running/3`). Um heartbeat durante um dispatch longo invalidava a segurança. Agora heartbeat escreve em coluna separada `heartbeated_at`.

### Board race conditions fechadas
Operações de card (claim, complete, block, etc.) e delete de board tinham janelas de race: cleanup podia bater em card já reclamado; um caller podia receber `nil`; deletar um board vazio podia cascatear um card criado no mesmo instante. Agora cada check e sua write são um passo atômico.

### Commitments/watches orphaned depois de agent delete
Deletar um agent deixava pra trás qualquer commitment/watch ligado a ele só por handle nunca-resolvido (referência órfã). Agora remove junto com o resto das bindings do agent.

### Trace falho agora é logged
Uma trace que falhava ao salvar (hiccup no banco) desaparecia silenciosamente. Agora logada como warning, mesma tolerância que o config journal tem.

---

*Atualizado em 22/07/2026*
