---
title: Vigilâncias
description: Pede ao Pepe para ficar de olho em algo e avisar-te assim que acontecer. Ele verifica sozinho, aguenta reinícios, e avisa exatamente uma vez.
---

## Vigilâncias

Uma vigilância responde a uma pergunta bem diferente de um cron: não "faz isto a uma hora certa", mas sim "fica de olho nisto e avisa-me assim que acontecer". Volta a verificar uma condição a cada intervalo e, no momento em que ela se torna verdadeira, avisa-te **uma vez** e pára. É durável: sobrevive a um reinício e ao fecho da própria sessão que a criou, e a resposta chega sempre pelo canal onde foi criada.

### Gatilho por sonda ou por agente

A parte barata de uma vigilância é o **gatilho**, que corre a cada intervalo; só quando ele dispara é que a notificação, essa sim potencialmente cara, chega a correr, e só uma vez. Há dois tipos:

- Uma **sonda** corre um comando de shell e não gasta um único token por verificação. Por predefinição, sucesso é código de saída 0, mas também podes exigir que uma string apareça na saída do comando. Usa uma sonda sempre que a condição for scriptável, como um URL estar acessível, uma tarefa ter escrito um ficheiro, ou um log conter determinada linha.
- Um gatilho de **agente** volta a fazer ao agente uma pergunta de sim/não a cada intervalo, com uma chamada ao modelo por verificação. Só faz sentido usá-lo quando decidir se a condição se cumpriu exige mesmo juízo.

Como as verificações de agente custam tokens, o intervalo mínimo delas é bem maior, 300 segundos, contra os 30 segundos de uma sonda. O intervalo predefinido, de qualquer forma, é de 120 segundos.

### O que envia quando dispara

Assim que o gatilho passa, a vigilância entrega uma mensagem, que pode ser um **modelo** fixo de texto, definido logo de início e sem qualquer chamada ao modelo, ou pode ser **composta pelo próprio agente** no momento do disparo, com uma única chamada, para conseguir incluir detalhe fresco, como um resumo do que realmente aconteceu.

Vale a pena conhecer a combinação de uma sonda gratuita a controlar uma mensagem composta pelo agente: a sondagem com `curl` não custa nada, e o modelo só entra em ação para escrever o resumo no instante exato em que a condição se cumpre.

### Cria uma vigilância pela CLI

A CLI só cria vigilâncias por sonda; as que são julgadas por um agente nascem sempre da conversa, onde o modelo já está a acompanhar tudo.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- A descrição (`"api-up"`) passa a ser o id da vigilância.
- `--probe` é o comando de shell a sondar; sem `--contains`, sucesso significa apenas que o comando termina com código 0.
- `--contains STR`, em alternativa, faz o sucesso depender de `STR` aparecer na saída do comando.
- `--message` é o texto a enviar quando dispara; omite-o e recebes uma confirmação predefinida.
- `--every` é o intervalo de sondagem em segundos, com mínimo de 30.
- `--deliver telegram:<chat>` envia a notificação para essa conversa; sem isto, a notificação vai parar ao log da aplicação.

Para gerir vigilâncias:

```bash
pepe watch list                 # todas as vigilâncias, com estado e contagem de verificações
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Fá-lo a partir do painel

A página **Watches**, sob `pepe serve`, mostra todas as vigilâncias com o seu estado, gatilho, intervalo e quantas verificações já gastou do seu orçamento; a partir dali dá para pausar, retomar e cancelar. As vigilâncias novas, essas, nascem sempre da CLI ou da conversa, que é onde se define o gatilho e o destino de entrega.

### Fá-lo pela conversa

Basta pedir em linguagem simples, e o agente cria a vigilância através da sua ferramenta `watch`. Tal como acontece com `schedule_task`, a ferramenta `watch` já vem ativada por predefinição (tira-a das ferramentas do agente se ele nunca dever criar uma), e cada criação continua a passar pelo mesmo pedido de permissão de sempre.

> Avisa-me quando o deploy terminar. Verifica a cada poucos minutos.

Para uma verificação scriptável, o agente configura uma sonda; para algo que exige juízo, configura um gatilho de agente, formulando ele próprio a pergunta de sim/não que responde a cada intervalo. Também pode optar por compor a mensagem de disparo com o modelo em vez de usar um texto fixo, de forma a que a notificação leve um resumo verdadeiro em vez de uma linha genérica. As ações da ferramenta `watch` são `create`, `list`, `pause`, `resume` e `cancel`.

Para manter tudo dentro de limites, no máximo 50 vigilâncias podem estar ativas ao mesmo tempo, e o Pepe recusa criar uma nova cuja condição seja idêntica a uma já em curso, evitando que se empilhem duplicados sem querer. Cada vigilância tem também um número máximo de verificações; se a condição nunca se tornar verdadeira dentro desse orçamento, a vigilância expira em silêncio, em vez de continuar a sondar para sempre.

### Entrega no canal de origem

No momento em que é criada, cada vigilância regista a sua **origem**: o canal e a conversa de onde nasceu. Quando dispara, é aí que entrega a resposta, mesmo depois de um reinício, seja numa conversa do Telegram (um envio direto), numa sessão de terminal ou WebSocket ligada, ou no log da aplicação. Num WebSocket, a notificação chega como um evento `"watch"` no canal; se passares um `session` estável ao entrares, continuas a recebê-la mesmo depois de reconectares, em vez de a receberes só no socket que por acaso criou a vigilância. No `pepe chat`, aparece impressa diretamente na consola. Já uma vigilância criada pela API HTTP sem estado, que não tem conversa nenhuma para responder, cai de volta para o log.

Duas garantias tornam isto fiável:

- **No máximo uma vez.** O novo estado da vigilância (normalmente "done") é gravado em disco *antes* de sequer se tentar a entrega. Se o processo falhar entre o disparo e a entrega, não volta a verificar nem a disparar segunda vez; só a entrega em si é repetida.
- **Entrega assim que der para alcançar.** Se uma vigilância dispara com o canal offline, por exemplo uma sessão de terminal já desligada, a mensagem fica retida e volta a ser tentada a cada ciclo até conseguir chegar. Recebes a notificação assim que voltares, sem que a vigilância tenha de voltar a verificar seja o que for.

Ao longo da sua vida, uma vigilância passa por um pequeno conjunto de estados: `pending` (ainda em vigilância), `paused`, `done` (disparou e foi entregue), `expired` (esgotou o seu orçamento de verificações), ou `cancelled`.

<div class="note"><strong>Sem base de dados para instalar, sem crontab.</strong> As tarefas agendadas continuam a ser simples registos em <code>~/.pepe/config.json</code> (sob <code>"crons"</code>), com um ficheiro JSONL de histórico por tarefa sob <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Já as vigilâncias vivem no mesmo pequeno ficheiro SQLite embutido dos compromissos, algo que não precisas de instalar nem de gerir. De um modo ou de outro, não há mais nada a manter em execução: o agendador inteiro é um temporizador dentro do próprio processo, que corre em qualquer superfície de vida longa que estiver de pé, seja o <code>pepe serve</code>, uma gateway, ou um <code>pepe chat</code> interativo, e pára quando paras essa superfície. Corre só uma de cada vez sobre a mesma configuração: com duas ao mesmo tempo, ambas disparariam, e uma vigilância acabaria por avisar-te duas vezes.</div>
