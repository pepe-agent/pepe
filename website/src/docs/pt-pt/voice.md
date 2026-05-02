---
title: Mensagens de voz
description: Uma mensagem de voz chega como texto. A transcrição acontece à entrada, antes de o agente correr.
---

## Mensagens de voz

Envia uma mensagem de voz ao teu bot do Telegram e o agente recebe **texto**. O áudio é
transcrito à chegada, antes de existir uma sessão e antes de qualquer decisão de
encaminhamento, por isso o que chega ao agente é uma mensagem vulgar.

Nem sempre foi assim. O gateway gravava o ficheiro na área de trabalho do agente e
entregava-lhe o caminho, deixando-o descobrir sozinho como escutar: encontrar um
transcritor, instalá-lo, executá-lo, ler o resultado. Cada mensagem de voz tornava-se um
pequeno projeto de investigação. Era lento, saía diferente de cada vez, e gastava uma
cancela de permissão só para ler a mensagem que acabara de chegar.

### Nada para configurar

Se já tens uma ligação de modelo à OpenAI ou à Groq, a transcrição já funciona. O Pepe
reaproveita essa credencial e pede ao provider o modelo de transcrição dele (`whisper-1` na
OpenAI, `whisper-large-v3-turbo` na Groq) em vez do modelo de chat com que a ligação foi
configurada. Envia uma mensagem de voz e ela é respondida. Não há nada a definir.

### Como a rota é escolhida

O Pepe tenta estas rotas por esta ordem, e qualquer uma delas pode não existir:

1. **`media.audio.model`**: uma ligação de modelo, referida pelo nome. A cadeia de
   `fallbacks` dessa ligação também se aplica aqui, por isso o failover não custa nada de
   extra.
2. **`media.audio.command`**: um comando local, por exemplo `whisper-cli -f {file}`. O
   `{file}` é substituído pelo caminho do áudio. Isto é tentado *antes* da deteção
   automática, de propósito: quem configurou um transcritor local fê-lo para o áudio não
   sair da máquina, e passar-lhe à frente para chamar um provider derrotaria o objetivo.
3. **Deteção automática**: a rota sem configuração descrita acima.
4. **Nada disponível**: o ficheiro vai para o agente, que se desenrasca com as ferramentas
   que tem. Esse caminho fica como rede de segurança; não é a porta de entrada.

### Porque é que transcrever primeiro faz diferença

Como as palavras existem antes de o encaminhamento correr, o encaminhamento consegue lê-las.
Daqui saem duas consequências, nenhuma delas possível enquanto a transcrição só aparecia
dentro do turno do agente:

- **Um comando barra falado funciona.** Diz `/help` ou `/stop` numa mensagem de voz e o
  comando é executado, tal como se o tivesses escrito, em vez de se tornar um turno do
  agente sobre um ficheiro largado numa pasta.
- **Um bot num grupo pode ser interpelado por voz.** Num grupo que exige menção, a cancela
  passa a ler as **palavras** em vez da legenda. Uma mensagem de voz não tem legenda, por
  isso antes disto não havia nada para a cancela ler, e era impossível dirigir-se ao bot a
  falar.

<div class="note"><strong>Só fala.</strong> É o áudio que se torna texto logo à porta. Uma
fotografia ou um documento continuam a ir para o agente, que tem olhos para uma e
ferramentas para o outro.</div>

### Configuração

Todas as chaves são opcionais e vivem em `media.audio`, no `~/.pepe/config.json`:

- `model`: o nome de uma ligação de modelo com a qual transcrever.
- `command`: um transcritor local. O `{file}` é substituído pelo caminho do áudio.
- `language`: uma sugestão de idioma passada ao provider.
- `max_mb`: limite de tamanho para o ficheiro recebido. Por omissão, `20`.
- `timeout`: quanto tempo uma transcrição pode demorar, em segundos. Por omissão, `60`.
- `echo`: devolve a transcrição ao chat como `📝 ...`, para quem falou conferir o que foi
  entendido.

```json
{
  "media": {
    "audio": {
      "model": "groq",
      "language": "pt",
      "max_mb": 20,
      "timeout": 60,
      "echo": true
    }
  }
}
```

Para manter o áudio na máquina, usa um comando em vez de uma ligação:

```json
{
  "media": {
    "audio": {
      "command": "whisper-cli -f {file}",
      "timeout": 120
    }
  }
}
```

### Salvaguardas

- **Um ficheiro abaixo de 1 KB é recusado antes de qualquer pedido.** Com esse tamanho está
  vazio ou truncado, e não apenas silencioso, e nenhum transcritor diria nada de útil sobre
  ele. Recusar não custa nada; enviá-lo custa um pedido.
- **Um ficheiro acima do `max_mb` é recusado da mesma forma**, antes de custar um pedido.
- **Um comando encravado é abandonado ao fim do `timeout`**, em vez de encravar a conversa
  que está atrás dele.
- **Um áudio sem fala nenhuma recebe uma resposta curta**, não um turno do agente. O
  ficheiro foi lido, apenas não tinha nada lá dentro, e responder a uma mensagem vazia só
  produziria uma resposta confusa.
