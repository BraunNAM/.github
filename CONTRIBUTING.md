# Contributing to BraunAbility IT & Engineering repositories

This file lives in `BraunNAM/.github` and serves as the **organization-wide default** contributing
guide: any repo in `BraunNAM` without its own `CONTRIBUTING.md` surfaces this one automatically
(GitHub's [community health file](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
convention). If you're about to copy a CI/CD, release, or installer pattern into a new repo, start
here.

## Shared CI/CD building blocks

- **Reusable label-gated workflows** — [`workflows/label-gated-msbuild.yml`](workflows/label-gated-msbuild.yml),
  [`workflows/label-gated-dotnet.yml`](workflows/label-gated-dotnet.yml),
  [`workflows/label-gated-node.yml`](workflows/label-gated-node.yml). Call one of these from a
  repo's own CI instead of hand-rolling a label-gated build/test job.
- **Release distribution (PDQ/Blob sync)** — [`scripts/pdq/README.md`](scripts/pdq/README.md) +
  [`workflows/publish-release-to-blob.yml`](workflows/publish-release-to-blob.yml). A shared,
  app-agnostic way to get a built release artifact from CI onto PDQ Deploy without ever putting a
  GitHub credential near a deployment target.
- **Installer design patterns** — [`docs/installer-design-patterns.md`](docs/installer-design-patterns.md).
  If your app ships a WiX MSI and/or runs under a privileged service account (e.g. a Windows Task
  Scheduler job), read this **before** wiring up credential handling in your installer — it covers
  a real credential-leakage pitfall (MSI log redaction only matches property *names*, not values)
  and the resulting pattern of keeping credential-touching steps in a standalone script instead of
  the installer.

## Governance & branch protection

Repo-level governance (branch protection, required status checks, CODEOWNERS, merge settings) is
managed by `BraunNAM/it-governance`'s Terraform control plane for any repo on a governed team's
roster. See that repo's `docs/onboarding.md` for how a repo gets onboarded, and the
`ci-cd-governance-audit` Copilot skill (installable via
`gh skill install BraunNAM/it-governance ci-cd-governance-audit --scope user --agent github-copilot --allow-hidden-dirs`)
to audit an existing repo against those standards, including the installer secret-handling check
above.

## Questions

These repos are internal to BraunAbility IT/Engineering; we don't monitor issues from outside the
org. If something here is unclear or you find a gap, open a PR or issue directly in `BraunNAM/.github`.
