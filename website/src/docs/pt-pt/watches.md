---
title: Vigilâncias
description: Cria monitores duráveis que avisam uma única vez quando uma condição se torna verdadeira.
---

## Vigilâncias

Uma vigilância responde a uma pergunta diferente: não "faz isto num horário", mas "fica de olho em algo e avisa-me no momento em que acontecer". Uma vigilância volta a verificar uma condição periodicamente e avisa-te **uma vez** quando ela se torna verdadeira, e depois pára. É durável: sobrevive a um reinício e ao fecho da sessão que a criou, e responde sempre no canal em que foi criada.

### Gatilhos por sonda versus por agente

A parte barata de uma vigilância é o **gatilho**, que corre a cada intervalo. Só quando o gatilho dispara é que a notificação (possivelmente cara) corre, uma vez. Há dois tipos de gatilho:

- Uma **sonda** corre um comando de shell e não custa tokens por verificação. O sucesso é o código de saída 0 por predefinição, ou podes exigir que uma string apareça na saída do comando. Usa uma sonda sempre que a condição for scriptável (um URL está acessível, uma tarefa escreveu um ficheiro, um log contém uma linha).
- Um gatilho de **agente** volta a perguntar ao agente uma pergunta de sim/não a cada intervalo, uma chamada ao modelo por verificação. Usa-o só quando decidir se a condição foi cumprida exigir juízo a sério.

Como as verificações de agente custam tokens, o intervalo mínimo delas é maior: 300 segundos para gatilhos de agente, 30 segundos para sondas. O intervalo predefinido é de 120 segundos.

### O que envia quando dispara

Quando o gatilho finalmente passa, uma vigilância entrega uma mensagem. Essa mensagem é ou um **modelo** fixo (um texto que defines à partida, sem chamada ao modelo) ou é **composta pelo agente** no momento do disparo (uma chamada ao modelo, uma vez), para poder incluir detalhe fresco, como um resumo do que de facto aconteceu.

### Cria uma vigilância pela CLI

A CLI cria vigilâncias por sonda. Vigilâncias julgadas por agente são criadas pela conversa, onde o modelo já está no ciclo.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- A descrição (`"api-up"`) torna-se o id da vigilância.
- `--probe` é o comando de shell a sondar. Sem `--contains`, sucesso significa que o comando sai com 0.
- `--contains STR` em vez disso faz o sucesso significar que `STR` aparece na saída do comando.
- `--message` é o texto a enviar quando dispara. Omite-o para uma confirmação predefinida.
- `--every` é o intervalo de sondagem em segundos (mínimo 30).
- `--deliver telegram:<chat>` envia a notificação para essa conversa. Omite-o e a notificação vai para o log da aplicação.

A gerir vigilâncias:

```bash
pepe watch list                 # todas as vigilâncias, com estado e contagem de verificações
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Fá-lo a partir do painel

Abre a página **Watches** sob `pepe serve` para ver cada vigilância com o seu estado, gatilho, intervalo, e quantas verificações já usou do seu orçamento. A partir daí podes pausar, retomar e cancelar uma vigilância. Vigilâncias novas são criadas pela CLI ou pela conversa, onde o gatilho e o destino de entrega são configurados.

### Fá-lo pela conversa

Pede em linguagem simples e o agente cria a vigilância através da sua ferramenta `watch`. Tal como `schedule_task`, a ferramenta `watch` tem de estar no conjunto de ferramentas do agente e passa pelo mesmo pedido de permissão em cada criação, por isso aplica-se a mesma barreira de duplo consentimento.

> Avisa-me quando o deploy terminar. Verifica a cada poucos minutos.

Para uma verificação scriptável o agente configura uma sonda. Para algo que precisa de juízo, configura um gatilho de agente, formulando uma pergunta de sim/não que responde a cada intervalo. Também pode escolher compor a mensagem de disparo com o modelo em vez de um modelo fixo, para que a notificação leve um resumo real em vez de uma linha enlatada. As ações da ferramenta `watch` são `create`, `list`, `pause`, `resume` e `cancel`.

Para manter as coisas limitadas, podem estar ativas no máximo 50 vigilâncias ao mesmo tempo, e o Pepe recusa uma vigilância nova cuja condição seja idêntica a uma já em execução, por isso não empilhas duplicados sem querer. Uma vigilância também tem um número máximo de verificações; se a condição nunca se tornar verdadeira dentro desse orçamento, a vigilância expira em silêncio em vez de sondar para sempre.

### Entrega no canal de origem

Uma vigilância regista a sua **origem**, o canal e a conversa a partir dos quais foi criada, no momento da criação. Quando dispara, entrega ali de volta, mesmo depois de um reinício, seja uma conversa do Telegram, uma sessão de terminal ou WebSocket ligada, ou o log da aplicação. Se a vigilância foi criada através da API HTTP sem estado (que não tem conversa para responder), recorre ao log.

Duas garantias tornam isto fiável:

- **No máximo uma vez.** O novo estado da vigilância (normalmente "done") é guardado em disco *antes* de a entrega ser tentada. Se o processo falhar entre o disparo e a entrega, não volta a verificar nem a disparar uma segunda vez. Só a entrega é repetida.
- **Entrega quando alcançável.** Se uma vigilância dispara enquanto o seu canal está offline (uma sessão de terminal que se desligou, por exemplo), a mensagem fica retida e é reenviada a cada ciclo até chegar. Recebes a notificação quando voltas, sem a vigilância voltar a verificar.

Uma vigilância passa por um pequeno conjunto de estados ao longo da sua vida: `pending` (ainda a vigiar), `paused`, `done` (disparada e entregue), `expired` (esgotou o seu orçamento de verificações) ou `cancelled`.

<div class="note"><strong>Sem base de dados, sem crontab.</strong> Tarefas e vigilâncias são registos simples em <code>~/.pepe/config.json</code>, e o histórico de execuções das tarefas é um ficheiro JSONL por tarefa sob <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Não há mais nada para instalar ou manter em execução. Todo o agendador é um temporizador dentro do processo que arranca quando corres <code>pepe serve</code> ou uma gateway, e pára quando os paras.</div>
