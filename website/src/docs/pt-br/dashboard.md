---
title: Painel
description: Use a interface web local para inspecionar e gerenciar agentes, modelos, canais e execuções.
---

O painel é a interface web local iniciada por `pepe serve`. Use-o para conversar com agentes, inspecionar traces, gerenciar conexões de modelo, configurar canais, revisar tarefas agendadas e gerar tokens de API sem editar JSON à mão.

## Acesso ao painel

O painel web fica aberto em localhost por padrão, o que é conveniente para o desenvolvimento local. No momento em que você o expõe além da sua máquina, coloque-o atrás de uma senha:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Você pode passar uma senha literal ou uma referência `${ENV_VAR}` para que o segredo fique fora do arquivo. Uma vez definida a senha, o painel exige entrar em `/login`. Limpe-a com `pepe dashboard password --clear`.

A senha é lida de `dashboard.password` na configuração (interpolada), com um recuo para a variável de ambiente `PEPE_DASHBOARD_PASSWORD`. Dois ajustes relacionados reforçam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores extras do cabeçalho `Host` que o painel aceita. Isso serve também como a lista de permissão contra o reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies reversos cujo cabeçalho `X-Forwarded-For` pode ser considerado confiável. Vazio por padrão, o que significa que nenhum cabeçalho de encaminhamento é confiável.

Vinculado a uma interface pública sem senha, o painel se fecha por padrão e bloqueia clientes remotos até que você defina uma.
