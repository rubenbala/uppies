# Security

Uppies handles a personal access token for a bank account and a local copy of the transactions
it has downloaded, so security reports are welcome and taken seriously.

## What Uppies can and cannot do

- It talks only to `api.up.com.au`, over HTTPS. The token is never sent anywhere else.
- The Up API does not allow moving money, so Uppies cannot. It can change transaction categories
  and tags and create, ping and delete webhooks.
- If you choose "Remember on this PC", the token is stored encrypted with Windows DPAPI in
  `%APPDATA%\Uppies\token.bin`.
- The local data file (`%APPDATA%\Uppies\store.uppies`) is encrypted with AES-256-GCM. Its key is
  protected by DPAPI together with your token.
- **Explore with sample data** (`-demo`) never contacts Up and never uses a real token.

Anyone who can run code as your Windows user, or who has your token, can still read your data.
If you think a token has leaked, revoke it at <https://api.up.com.au/getting_started> and create a
new one.

## Reporting a vulnerability

Please report problems privately rather than in a public issue:

- Use GitHub's [private vulnerability reporting](https://github.com/rubenbala/uppies/security/advisories/new)
  on this repository, or
- email <email@ruben.net.au>.

Include what you found, how to reproduce it, and which version or commit you tested. I'll
acknowledge a report within a few days and aim to fix confirmed issues promptly. Uppies is a
spare-time project, so there is no formal timeline or bounty.

## When filing any issue

**Never paste a real access token, `token.bin`, `store.uppies`, or screenshots showing real
balances, merchants or account names.** Use `-demo` mode to reproduce problems and to take
screenshots. If you pasted a token by accident, revoke it straight away.

## Supported versions

Only the latest release (or the `main` branch) receives fixes.
