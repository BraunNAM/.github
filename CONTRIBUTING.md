# Contributing to BraunAbility IT & Engineering repositories

This file lives in `BraunNAM/.github` and serves as the **organization-wide default** contributing
guide: any repo in `BraunNAM` without its own `CONTRIBUTING.md` surfaces this one automatically
(GitHub's [community health file](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
convention). If you're about to copy a CI/CD, release, or installer pattern into a new repo, start
here.

## Shared CI/CD building blocks

- **Reusable label-gated workflows** — [`.github/workflows/label-gated-msbuild.yml`](.github/workflows/label-gated-msbuild.yml),
  [`.github/workflows/label-gated-dotnet.yml`](.github/workflows/label-gated-dotnet.yml),
  [`.github/workflows/label-gated-node.yml`](.github/workflows/label-gated-node.yml). Call one of
  these from a repo's own CI instead of hand-rolling a label-gated build/test job.
  See [`label-gated-dotnet.yml` options](#label-gated-dotnetyml-options) below for its optional
  test, coverage and pack steps.
- **Release distribution (PDQ/Blob sync)** — [`scripts/pdq/README.md`](scripts/pdq/README.md) +
  [`.github/workflows/publish-release-to-blob.yml`](.github/workflows/publish-release-to-blob.yml).
  A shared, app-agnostic way to get a built release artifact from CI onto PDQ Deploy without ever
  putting a GitHub credential near a deployment target.
- **Installer design patterns** — [`docs/installer-design-patterns.md`](docs/installer-design-patterns.md).
  If your app ships a WiX MSI and/or runs under a privileged service account (e.g. a Windows Task
  Scheduler job), read this **before** wiring up credential handling in your installer — it covers
  a real credential-leakage pitfall (a credential's *value* is only hidden from MSI verbose logs
  when its exact property name is explicitly listed in `MsiHiddenProperties` — there's no automatic
  redaction based on the name containing `PASSWORD`) and the resulting pattern of keeping
  credential-touching steps in a standalone script instead of the installer.

### `label-gated-dotnet.yml` options

By default the workflow only runs `dotnet build`, exactly as it always has. Test, coverage and pack
are **opt-in** and run as extra steps inside the same build job. They never add jobs, so the
check-run names stay `<caller-job> / Build Gate (requires 'Auto Build & Test' label)` and
`<caller-job> / <job-name>`. Turning an option on doesn't change any required status check in
`BraunNAM/it-governance`. A failing test or a missed coverage threshold fails that build check.

| Input | Default | What it does |
|---|---|---|
| `job-name` | `Build (.NET SDK)` | Check-run display name. Changing it renames the required check. |
| `solution` | *(required)* | `.sln`/`.slnx`/`.csproj` to build. |
| `dotnet-version` | `8.0.x` | .NET SDK version. |
| `configuration` | `Release` | Build/test/pack configuration. |
| `runs-on` | `windows-2022` | Runner. Use `ubuntu-latest` for tests that need Linux containers (e.g. Testcontainers). |
| `run-tests` | `false` | Run `dotnet test` after the build. Results (`.trx`) are uploaded as an artifact (see the naming note below). |
| `test-project` | `solution` | What to test, if not the whole solution. |
| `test-filter` | *(none)* | `--filter` expression, e.g. `Category!=Integration` to skip container tests on Windows. |
| `extra-test-args` | *(none)* | Extra `dotnet test` arguments, split on whitespace. Double quotes group a value and are removed, e.g. `-- NUnit.Where="cat != Integration"`. |
| `collect-coverage` | `false` | Collect Cobertura coverage (turns on tests too) and add a coverage summary to the job summary. The report tool also installs the .NET 8 SDK, after the test and pack steps. |
| `coverage-collector` | `Code Coverage;Format=cobertura` | `--collect` value. The default (Microsoft Code Coverage) ships with `Microsoft.NET.Test.Sdk`. Use `XPlat Code Coverage` for coverlet. |
| `coverage-threshold` | `0` | Minimum merged **line** coverage %. `0` reports without enforcing. |
| `coverage-assembly-filters` | *(none)* | ReportGenerator `-assemblyfilters`, e.g. `+Piper.*;-*.Tests`, so the threshold only counts the libraries you care about. |
| `pack` | `false` | `dotnet pack` and upload `.nupkg`/`.snupkg` as an artifact. It never pushes to a feed; publishing stays in the repo's signed release workflow. |
| `pack-project` | `solution` | What to pack, if not the whole solution. |
| `pack-version` | *(none)* | Package version override (`-p:Version=`). |

Outputs: `line-coverage`, `test-results-artifact` and `packages-artifact`. Each is empty when its
option is off.

Artifact names are `test-results-<slug>-<hash>` and `packages-<slug>-<hash>`. `<slug>` is
`job-name` lower-cased, with each run of characters outside `A-Z a-z 0-9 . _ -` replaced by `-`.
`<hash>` is the first 8 hex characters of a SHA-256 of all the call's inputs. The hash keeps
matrix legs and repeated `job-name`s from colliding, and it stays stable across re-runs. Don't
build the name yourself. A downstream job should read it from the outputs:

```yaml
  publish:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: ${{ needs.build.outputs.packages-artifact }}
```

Example: unit tests with an 80% gate on Windows, plus a second call that runs container-based
integration tests on Linux. Each call gets its own job id and check name.

```yaml
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, labeled, synchronize, reopened]

jobs:
  build:
    uses: BraunNAM/.github/.github/workflows/label-gated-dotnet.yml@main
    with:
      job-name: Build & Test Piper (.NET 10)
      solution: Piper.slnx
      dotnet-version: 10.0.x
      run-tests: true
      test-filter: Category!=Integration
      collect-coverage: true
      coverage-threshold: 80
      coverage-assembly-filters: +Piper.*;-*.Tests;-*.Testing
      pack: true

  integration:
    uses: BraunNAM/.github/.github/workflows/label-gated-dotnet.yml@main
    with:
      job-name: Integration Tests Piper (.NET 10)
      solution: Piper.slnx
      dotnet-version: 10.0.x
      runs-on: ubuntu-latest
      run-tests: true
      test-filter: Category=Integration
```

The test step uses VSTest-mode `dotnet test` arguments (`--logger trx`, `--collect`), which is the
SDK default. Don't opt a repo into Microsoft.Testing.Platform mode (`"test": { "runner":
"Microsoft.Testing.Platform" }` in `global.json`) if it uses `run-tests`. xUnit v3, NUnit and MSTest
all run under VSTest through their usual `*.runner.visualstudio`/adapter packages.

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
