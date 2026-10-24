# Installer design patterns for privileged/scheduled-task apps

This is a shared reference for building a WiX MSI installer for an internal app that deploys to a
company-managed server and runs under a privileged service account (e.g. a daily Windows Task
Scheduler job running as `BraunAmSer`). It generalizes two non-obvious design decisions first made
for `BraunNAM/eng-admin-diag-tool` and since repeated across every console app in
`BraunNAM/dealermade-programs` (`DealerMadeFTP`
[PR #10](https://github.com/BraunNAM/dealermade-programs/pull/10),
`ResolutionChangingStoring` [PR #11](https://github.com/BraunNAM/dealermade-programs/pull/11),
`Dlr_Md_Img_CleanUp` [PR #9](https://github.com/BraunNAM/dealermade-programs/pull/9)) — so the next
app doesn't have to rediscover them from scratch, or worse, skip them.

For the PDQ/Blob release-distribution half of the pipeline (how a built MSI gets from CI onto a
target machine), see [`scripts/pdq/README.md`](../scripts/pdq/README.md). This document is about
what the MSI itself should (and should not) do once it's there.

## 1. Never let a privileged credential touch the installer

If your app's deployment involves a privileged credential — most commonly a service-account
password used to register a Windows Task Scheduler job (`schtasks.exe` / the Task Scheduler COM
API, both of which take the password as a literal string) — **do not** try to pass that credential
through:

- an MSI property (even one named to look like it would be redacted),
- a WiX custom action or `CustomActionData`,
- any installer UI field (wizard or silent).

MSI's built-in verbose-log redaction (`msiexec /l*v`) only masks **property *names*** containing
`PASSWORD`. It does not inspect property *values*, so a credential that ends up embedded inside a
*derived* command line — for example a generated `schtasks.exe` invocation built from a
non-`PASSWORD`-named property like `WixQuietExecCmdLine` — is written to the log in plaintext. MSI
logs are frequently retained by deployment tooling (`%windir%\Temp\MSI*.log`), so this is a real
credential-leakage path, not a theoretical one.

**Pattern:** keep every credential-touching step in a separate, standalone, human-run script that
prompts for the credential interactively (`Get-Credential`) and never persists or echoes it —
deliberately decoupled from the MSI/installer entirely, whether the install runs silently or
through a wizard. The reference implementation is
[`scripts/Register-ScheduledTask.ps1`](https://github.com/BraunNAM/dealermade-programs/blob/main/scripts/Register-ScheduledTask.ps1)
in `dealermade-programs`: the MSI only drops files and registers an Add/Remove Programs entry; an
IT/ops operator runs this script once per server, per app, as a separate deployment step, and the
plaintext password only ever exists in that script's process memory for the duration of the call.

## 2. A WixUI wizard is fine — it's cosmetic, and silent installs skip it anyway

A basic `WixUI_Minimal` wizard (License → Progress → Finish dialogs, via the
`WixToolset.UI.wixext` PackageReference + `<ui:WixUI Id="WixUI_Minimal" />` +
`<WixVariable Id="WixUILicenseRtf" ... />`) is purely cosmetic for an interactive/manual install
(e.g. an admin double-clicking the MSI, or PDQ's "preview" mode) and is **automatically skipped
entirely** by a silent `/quiet` install — which is the real PDQ/ops deployment path in practice.

Adding a wizard for visual consistency across installers (as done for `StockPhotoPackager`,
`eng-admin-diag-tool`, and every `dealermade-programs` console app) does **not** reintroduce any of
the risk described in pattern 1 above, as long as the wizard still has zero interaction with
credential-handling logic — it should only ever drive file placement and the Add/Remove Programs
entry.

One related detail: a headless/background console app (no tray icon, no window) should still skip
the Start Menu shortcut even once it gains a wizard — there's nothing for a user to launch from it.

## Reference implementations

- [`BraunNAM/eng-admin-diag-tool`](https://github.com/BraunNAM/eng-admin-diag-tool) — the original
  template: tests, `ci.yml`/`pr-dev-build.yml`/`release.yml`, WiX v5 installer, `SecretProvider.cs`,
  PDQ blob sync.
- `BraunNAM/dealermade-programs` console apps, each showing the installer-with-wizard-but-
  no-credential-handling pattern plus the standalone scheduled-task script:
  [`DealerMadeFTP` (PR #10)](https://github.com/BraunNAM/dealermade-programs/pull/10),
  [`ResolutionChangingStoring` (PR #11)](https://github.com/BraunNAM/dealermade-programs/pull/11),
  [`Dlr_Md_Img_CleanUp` (PR #9)](https://github.com/BraunNAM/dealermade-programs/pull/9).

## Why WiX v5

Every installer above pins `WixToolset.Sdk`/`WixToolset.UI.wixext` to `5.0.2`, deliberately staying
below WiX v6+: FireGiant introduced a paid "Open Source Maintenance Fee" for v6, and v7 build-blocks
without an accepted EULA confirming payment. v5 predates that fee and remains fully free to use; it
gets no further updates, which is an accepted trade-off. Revisit if BraunAbility ever sponsors WiX.
