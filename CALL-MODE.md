# Call Mode — fast-response protocol

When the user is on a live customer call and pings me, I switch to **call mode**.

## Triggers

Auto-engage on any of these phrases (or obvious equivalents):
- "on a call" / "in a call" / "live call"
- "quick" / "NRT" / "now" / "fast"
- "customer asking" / "customer wants to know"
- "i need an answer right now"

## Time budget

**≤ 30 seconds end-to-end. Target: < 5 seconds.**

### Lookup order (fastest first)

0. **`/Volumes/data/vscode/MyProjects/_nrt-search.sh <term>`** — federated grep across **all** identity-domain projects' `kb/INDEX.md` files (currently `WorkloadIdentity` + `extid-migration-lab`). Use this **first** — the answer may live in a sibling project. Sub-20 ms. Returns `<project>/kb/INDEX.md:<line>: <heading row>` and the row itself contains the article `path:line`.
1. **`grep <term> kb/INDEX.md`** — this project's flat heading index only. Use when you know the topic is in-scope. Sub-100 ms.
2. **`grep -r <term> kb/`** — full KB body grep if the index miss is suspicious.
3. **`view kb/<path>` with `view_range`** at the matched line — open exactly the section.
4. **`research-cache/`** as a deeper layer if the KB distillation is too thin.

### Allowed / forbidden

- ✅ Allowed: `grep` over `kb/**` and `research-cache/**`, `view` 1–2 files, simple SQL on `inbox_entries`.
- ❌ Forbidden: subagent dispatch, `web_fetch`, `web_search`, multi-step research, building anything.

### Why no subagents in call mode

Subagents take **120–470 seconds to return** (measured from the bootstrap session). A local grep returns in <1 second. For a live customer call, even 30 seconds of silence is uncomfortable — minutes of subagent dispatch is unusable. Subagents are reserved for **after-call follow-up** (see bottom of this doc).

## Response format

```
✅/⚠️/❓ <one-line direct answer customer can hear>

- supporting bullet 1 (≤ 1 line)
- supporting bullet 2 (≤ 1 line)
- (optional) supporting bullet 3

Source: kb/<section>/<file>.md
```

### Confidence tags

| Tag | Meaning |
|-----|---------|
| ✅ | KB-grounded with a direct citation |
| ⚠️ | Partial answer — KB covers part of it, or I'm inferring from adjacent KB content |
| ❓ | Not in KB. I give a best guess and flag it for follow-up |

### Pricing answers

Always append: `⚠️ snapshot from <date in kb/04-pricing/*>, verify after call.`

## What I will NOT do in call mode

- Go silent for minutes researching
- Dispatch subagents (they take 2–7 minutes)
- Fetch web pages (network adds seconds and uncertainty)
- Write any code or docs
- Re-explain the architecture from scratch
- Caveat-stack ("it depends on...") — pick the most likely answer and own it

## After-call follow-up (subagents allowed here)

If a `❓` came up during the call, I'll:
1. Log it to `inbox_entries` with the question and customer context.
2. After the call ends (you say "off the call" / "wrap up"), offer to dispatch a research subagent for it and update the KB.
3. If new content lands in the KB, run `python3 scripts/build-index.py` to refresh `kb/INDEX.md`.

## Maintaining the index

`kb/INDEX.md` is auto-generated. After any KB edit:

```bash
python3 scripts/build-index.py
```

Output: 1000+ heading rows across all sections, ~95 KB. Single grep over this
file is the fastest path to the right article+line for any topic.

## Example exchanges

### Good
> User: "on a call, customer asking — does ExtID support SAML as an outbound IdP?"
>
> Me: ✅ Yes — generic OIDC and SAML federated IdPs are supported in ExtID for customers.
>
> - Configure under Identity providers → Custom (OpenID Connect / SAML)
> - Same admin pattern as B2C federated IdPs
>
> Source: `kb/02-features/03-identity-providers.md`

### Good
> User: "quick — MAU price above 50K?"
>
> Me: ✅ $0.00325 per MAU between 50K and 100K (paraphrased — check KB for tiers above 100K).
>
> ⚠️ snapshot from 2025-07-09, verify on https://azure.microsoft.com/pricing/details/active-directory/external-identities/ after the call.
>
> Source: `kb/04-pricing/02-free-tier-and-thresholds.md`

### Good (no answer)
> User: "live — do they support NemID?"
>
> Me: ❓ Not in KB. Best guess: only via generic OIDC/SAML federation, not as a built-in IdP. Logged to inbox for post-call research.
>
> Source: nothing direct — see `kb/02-features/03-identity-providers.md` "Government/national IdPs" gap section.

### Bad — would NOT do this in call mode
> User: "on a call, what about migration tooling?"
>
> Me: *(spends 5 minutes dispatching a subagent to deeply analyze migration tooling)* ❌
