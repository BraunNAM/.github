# PDQ release sync

A shared, app-agnostic system for getting a GitHub Release artifact from CI onto
[PDQ Deploy](https://www.pdq.com/pdq-deploy/) (`na-baw-pdq`) for rollout, without ever putting a
GitHub credential — or any Entra ID app registration — anywhere near a deployment target.

It has two halves:

- **Publish** — [`workflows/publish-release-to-blob.yml`](../../.github/workflows/publish-release-to-blob.yml),
  a reusable GitHub Actions workflow any repo's release job can call to push its built artifact to
  a shared Azure Blob Storage account.
- **Pull** — [`Sync-ReleaseFromBlob.ps1`](./Sync-ReleaseFromBlob.ps1), a single generic PowerShell
  script every app's PDQ package calls (with its own parameters) to fetch and verify the latest
  artifact before installing it.

## Why this shape

- **One script and one workflow for every app**, instead of each repo hand-rolling its own
  publish/pull plumbing. Onboarding a new app is a config/secrets checklist (below), not new code.
- **No Entra ID app registrations.** `na-baw-pdq` is an on-prem/non-Azure host with no Azure
  identity of its own, so Managed Identity isn't available there, and standing up an Entra app
  registration requires a directory role most CI/automation identities don't have. Instead, each
  app's container uses **container-scoped SAS tokens backed by stored access policies**:
  - A `publisher` policy (Write/Add/Create) — its SAS lives only as that repo's own GitHub Actions
    secret, used solely by its release workflow.
  - A `reader` policy (Read/List) — its SAS lives only in 1Password, used solely by the PDQ pull
    script for that one app.

  Stored access policies mean a compromised or rotated token for one app never requires touching
  the storage account key (which would invalidate every other app's tokens too) — you just edit or
  delete that one policy.
- **One container per app.** Even though every app shares the same storage account
  (`stnamreleasesync`, in subscription `lz-nam-dev-001`, resource group
  `rg-lz-nam-dev-001-sandbox-stack-eval-001`), each app's blobs, policies, and SAS tokens are
  scoped to its own container — a leaked token or a bug in one app's workflow can't reach another
  app's artifacts.
- **Checksums, not blind trust.** The publish workflow always writes a sibling `<blob>.sha256`
  file; the pull script always verifies it before overwriting the local staged copy, so a partial
  upload or corrupted download fails loudly instead of silently shipping a broken installer.
- **Idempotent pulls.** The pull script hashes whatever is already staged locally and skips the
  download entirely if nothing changed, so it's safe to run from a PDQ schedule (e.g. daily) rather
  than needing a push/webhook trigger from GitHub.

## Onboarding a new app

1. **Create its container** in `stnamreleasesync` (reuse the existing storage account; don't
   create a new one per app) with `publisher` and `reader` stored access policies, then generate a
   SAS from each policy:
   ```powershell
   $key = (az storage account keys list --account-name stnamreleasesync `
     --resource-group rg-lz-nam-dev-001-sandbox-stack-eval-001 `
     --subscription 026a8b85-6177-4970-912a-c4f1568ee859 -o json | ConvertFrom-Json)[0].value

   az storage container create --account-name stnamreleasesync --account-key $key `
     --name <app-name> --public-access off

   $expiry = (Get-Date).AddYears(2).ToString("yyyy-MM-ddTHH:mmZ")
   az storage container policy create --account-name stnamreleasesync --account-key $key `
     --container-name <app-name> --name publisher --permissions wac --expiry $expiry
   az storage container policy create --account-name stnamreleasesync --account-key $key `
     --container-name <app-name> --name reader --permissions rl --expiry $expiry

   az storage container generate-sas --account-name stnamreleasesync --account-key $key `
     --name <app-name> --policy-name publisher -o tsv
   az storage container generate-sas --account-name stnamreleasesync --account-key $key `
     --name <app-name> --policy-name reader -o tsv
   ```
2. **Store the publisher SAS** as that app's own repo secret:
   `gh secret set AZURE_RELEASE_PUBLISHER_SAS --repo <org>/<repo>`.
3. **Store the reader SAS** as a new 1Password item (category "API Credential", field
   `credential`) in `svc-baa-applications`, named e.g. `<app-name>-pdq-reader-sas`.
4. **Call the reusable workflow** from the app's own release workflow, after its build/upload step:
   ```yaml
   publish:
     needs: build
     uses: BraunNAM/.github/.github/workflows/publish-release-to-blob.yml@main
     with:
       artifact-name: my-app-dev-build
       file-name: MyApp-Prod.msi
       storage-account: stnamreleasesync
       container: <app-name>
       blob-name: MyApp-Prod.msi
     secrets:
       sas-token: ${{ secrets.AZURE_RELEASE_PUBLISHER_SAS }}
   ```
5. **Add a PDQ package** on `na-baw-pdq` with a PowerShell step calling
   `Sync-ReleaseFromBlob.ps1` with that app's parameters, followed by PDQ's normal Install step
   pointed at the same `-DestinationPath`:
   ```powershell
   .\Sync-ReleaseFromBlob.ps1 `
     -StorageAccount stnamreleasesync -Container <app-name> `
     -BlobName MyApp-Prod.msi `
     -DestinationPath C:\PDQStaging\MyApp\MyApp-Prod.msi `
     -OnePasswordItem <app-name>-pdq-reader-sas
   ```
   Schedule the package (e.g. daily) rather than relying on a push trigger.

See [`eng-admin-diag-tool`](https://github.com/BraunNAM/eng-admin-diag-tool) for the first
real example of all of the above wired end-to-end.
