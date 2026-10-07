# PinGo

SaaS multi-tenant de **cobrança inteligente via Pix**: a empresa cadastra clientes e cobranças, o devedor abre um link público e o Pix é gerado na hora, uma **régua de cobrança** envia lembretes automáticos e o pagamento é confirmado por **webhook**, que interrompe os lembretes sozinho.

> **Status:** em fase de especificação. A spec está pronta (v0.4) e a implementação ainda não começou.
> Projeto de portfólio: o Pix roda no **modo de teste do Stripe** e e-mail e SMS são **simulados**.

## Stack prevista

Java 21 · Spring Boot · PostgreSQL (Flyway, Row Level Security) · Redis · RabbitMQ · Stripe · Docker Compose · Terraform e AWS (documentados com níveis de prova)

## Destaques de engenharia

- Isolamento entre tenants em 4 camadas (JWT, filtro de query, FKs compostas e RLS)
- Webhook com assinatura HMAC validada manualmente, idempotência e proteção contra replay
- Pix gerado sob demanda, com chave de idempotência no PSP
- Transactional outbox, retry com backoff, DLQ e worker retomável
- Segurança guiada pelo OWASP ASVS nível 2 (Argon2id, JWT com algoritmo fixado, CPF criptografado, refresh token em cookie `HttpOnly`)
- Contrato OpenAPI primeiro, consumido por um repositório de front-end separado

## Documentação

- [Especificação](docs/spec.md): requisitos, regras, arquitetura, segurança, critérios de aceite e plano de fases
- [Schema do banco](src/main/resources/db/migration/V1__init_schema.sql)
- `docs/phases/`: spec e tarefas de cada fase de desenvolvimento

## Como rodar

Disponível a partir da Fase 1.

## Repositórios

- `pingo-api` (este): back-end, spec e infraestrutura
- `pingo-web`: front-end
