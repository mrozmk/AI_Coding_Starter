---
status: empty
populated_by: /refresh-brief
description: Operational facts about pricing, plans, billing — what the code needs to know about the business model
---

# Memory: Business Model & Pricing

> Operational projection of business rules into code-relevant facts. Seeded by `/refresh-brief` from PRD when pricing / monetization / billing content is present.
>
> Scope: only what affects code (plan IDs, feature gates, Stripe events, quota rules). Storytelling and positioning belong in PRD, not here.
>
> While `status: empty`, skip loading this file.

---

## Plans

| Plan | Price | Limits | Feature gate |
|------|-------|--------|--------------|
| {plan} | {price} | {quotas} | {flag / role} |

## Billing events

- {event} → {effect on user/account state}

## Feature gates

- {feature} → {plans that unlock it}

## Quotas & rate limits

- {resource} → {limit per plan}

## Webhooks

- {provider event} → {handler / job}
