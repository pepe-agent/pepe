# Notas da Versão — 0.15.0

Uma versão focada em **aprender e se adaptar**. Agentes agora aprendem com suas reações no Telegram, você consegue rodar o servidor em qualquer interface de rede, comparar modelos lado a lado, e os traços de execução agora falam com Langfuse. Por dentro, slots de plugin tomaram conta da seleção de modelo e ritmo de heartbeat, e você tem um novo jeito de permitir ferramentas sem estar pedindo aprovação a toda hora.

---

## ✨ Novidades

### Agentes agora aprendem quando você reage com 👍 ou 👎 às suas mensagens no Telegram

Toda vez que você coloca um like ou deslike (👍 ou 👎) na última mensagem de um agente no Telegram, ele anota aquilo como feedback — o que funcionou, o que não funcionou — e lembra disso nas próximas conversas. É um aprendizado contínuo, sem você ter que digitar nada. Se você pressionar 👍, o agente registra "isto aqui funcionou, repete". Se pressionar 👎, registra "evita fazer assim de novo". O agente nunca responde à reação em si, só aprende com ela.

📍 *Como usar: envie uma mensagem do agente, clique em 👍 ou 👎 no Telegram*

### Compare modelos lado a lado com `mix pepe eval --models`

Agora você consegue rodar o mesmo teste automático contra vários modelos de uma vez e ver qual deles sai melhor. Basta listar os modelos que quer testar (`--models model-a,model-b,model-c`) e o resultado mostra um relatório de sucesso/falha para cada um, sem alterar a configuração de nenhum agente.

```bash
mix pepe eval agent-boundaries --models modelo-a,modelo-b,modelo-c
```

📍 *Onde rodar: terminal, comando `mix pepe eval`*

### Nova suíte de testes automáticos `agent-boundaries`

Criamos um pacote de testes que verifica se seus agentes conseguem reconhecer o que NÃO conseguem fazer — se você pedir para mover dinheiro real, acessar um agente que não existe ou chamar um serviço desligado, o agente admite "não dou conta disso" em vez de fingir que funcionou. É uma garantia de honestidade.

📍 *Onde ver: `mix pepe eval agent-boundaries`*

### Traços de execução agora exportam para Langfuse (ou qualquer backend OTLP)

Se você usa Langfuse (ou qualquer sistema que fale o protocolo OTLP) para monitorar seus agentes, agora o Pepe envia os traços automaticamente — tempo de execução, tokens gastos, qual modelo foi usado, quais tools foram chamadas, tudo. Basta configurar uma variável de ambiente e funciona. Se a exportação falhar por qualquer motivo, a conversa continua normalmente, a falha fica isolada.

📍 *Como ativar: defina `OTEL_EXPORTER_OTLP_ENDPOINT`*

### Persona de agente gerenciável direto no Langfuse

Você consegue agora guardar a persona (o "jeito" de ser) de um agente não no arquivo de configuração, mas no Langfuse — e editar lá sem precisar reiniciar o Pepe. A mudança aparece em poucos minutos. Se Langfuse ficar fora do ar, o agente volta para a persona local automaticamente. Por agora é opcional: alguns agentes com `langfuse_prompt` configurado, outros continuam lendo do `config.json`.

📍 *Como usar: `mix pepe agent add NAME --langfuse-prompt NOME_DO_PROMPT`*

### Saldo pré-pago para projetos — um verdadeiro freio para quem cobra

Um projeto pode ter um saldo de créditos (fundos de verdade, não só um limite mensal): `mix pepe project credit projeto-x 100.00` adiciona créditos, `mix pepe project balance projeto-x` mostra quanto sobrou. Quando acaba, o agente recusa novas chamadas até ter crédito de novo. Diferente do limite mensal que reseta, esse saldo é consumido mesmo. Um webhook genérico deixa seu próprio sistema de pagamento creditar automaticamente quando receber o pagamento de um cliente — sem você precisar vir cá configurar manualmente.

📍 *Onde ver: dashboard › Projetos (badge de saldo aparece quando já tiver créditos)*

### Nova opção de permissão: "Permitir com quaisquer parâmetros" pela sessão

Antes você tinha duas escolhas: dizer "sim para este comando com estes parâmetros" ou "sim para qualquer parâmetro deste comando para sempre". Agora tem um meio termo: "sim para quaisquer parâmetros desta tool pelo resto desta conversa" — útil quando você confia no agente naquele momento, mas não quer "para sempre" gravado na config. Aparece em todo lugar que permissão é pedida (Telegram, dashboard, terminal), e desaparece quando a conversa termina.

📍 *Onde ver: qualquer prompt de permissão no Telegram ou dashboard*

### Slots de plugin agora cobrem "qual modelo usar" e "quando chamar o assistente"

Você consegue instalar um plugin que decide qual modelo cada conversa usa (em vez de vir do agente), ou que decide se o assistente de fundo deve chamar agora ou aguardar. Antes isso era código fixo; agora são pontos de extensão personalizáveis.

---

## ⚡ Mudanças

### Pedidos de permissão ficam mais sérios: sem emojis

O texto que pede aprovação para rodar uma ferramenta (no Telegram, no dashboard, no terminal) agora é mais formal — sem emojis — para deixar claro que é uma decisão de segurança de verdade, não um bate-papo casual.

### `mix pepe serve` agora se conecta só em localhost por padrão

Antes, `mix pepe serve` ouvia em todas as interfaces de rede (`0.0.0.0`) — e sem autenticação configurada, isso significava que qualquer máquina na rede conseguia chamar uma API de IA sem senha. Agora só ouve em `127.0.0.1` (seu próprio computador) por padrão. Se você precisa acessar de outra máquina na rede (ou roda num container atrás de um proxy reverso), use `--bind lan` pra voltar ao comportamento antigo.

📍 *Se precisar: `mix pepe serve --bind lan`*

---

## 🐛 Correções

### Agente não inventa mais um falso ritual de confirmação em texto

Quando um pedido de permissão expirava sem resposta, o agente tentava contornar pedindo "digite essa frase mágica para confirmar" — que não funcionava, expirava da mesma forma, e se repetia. O agente agora sabe que a única forma de conseguir permissão é respondendo ao prompt de verdade (botão ou comando), não digitando frases inventadas.

---

*Atualizado em 11/08/2026*
