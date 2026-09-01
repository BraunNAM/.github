# BraunAbility IT — Production Applications

This organization hosts the internal application source code for BraunAbility's Production Systems and IT teams.

## Repositories

All production application repositories follow a consistent structure:
- `.github/workflows/ci.yml` — automated build and validation
- `.gitleaks.toml` — secret scanning configuration
- `.env.1password` — credential references (secrets stored in 1Password, never in code)
- `README.md` — purpose, architecture, and deployment notes

## CI / CD

Pull request builds are **opt-in** via the **Auto Build & Test** label.  
Merges to `main` always trigger a build automatically.

## Secret Management

All credentials are managed through [1Password](https://1password.com) and injected at runtime.  
See individual repository READMEs for environment setup instructions.
