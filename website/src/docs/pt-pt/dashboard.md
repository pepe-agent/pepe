---
title: Painel
description: Usa a interface web local para inspecionar e gerir agentes, modelos, canais e execuções.
---

O painel é a interface web local iniciada por `pepe serve`. Usa-o para conversar com agentes, inspecionar traces, gerir ligações de modelo, configurar canais, rever tarefas agendadas e gerar tokens de API sem editar JSON à mão.

## Acesso ao painel

O painel web fica aberto em localhost por predefinição, o que é cómodo para o desenvolvimento local. No momento em que o expõe para além da sua máquina, coloque-o atrás de uma palavra-passe:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Pode passar uma palavra-passe literal ou uma referência `${ENV_VAR}` para que o segredo fique fora do ficheiro. Uma vez definida a palavra-passe, o painel exige iniciar sessão em `/login`. Limpe-a com `pepe dashboard password --clear`.

A palavra-passe é lida de `dashboard.password` na configuração (interpolada), com recurso a variável de ambiente `PEPE_DASHBOARD_PASSWORD`. Duas definições relacionadas reforcam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores adicionais do cabeçalho `Host` que o painel aceita. Isto serve também de lista de permissões contra o reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies inversos cujo cabeçalho `X-Forwarded-For` pode ser considerado fidedigno. Vazio por predefinição, o que significa que nenhum cabeçalho de encaminhamento é considerado fidedigno.

Vinculado a uma interface pública sem palavra-passe, o painel fecha por predefinição e bloqueia os clientes remotos até o utilizador definir uma.
