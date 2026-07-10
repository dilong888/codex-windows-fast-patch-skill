# Repository Instructions

## Scope

- These instructions apply to the entire repository.
- This project is Windows-specific. Do not run the MSIX/ASAR repair flows on macOS or Linux.
- Treat `README.md`, `README.en.md`, and `SKILL.md` as the source of truth for user-facing setup, usage, and agent workflow guidance.

## Before Editing

- Inspect the current branch, working tree, and remote before making changes.
- Preserve user changes. Do not discard, overwrite, or reset uncommitted work unless the user explicitly asks for it.
- Prefer a dedicated `codex/` branch for non-trivial work.
- Keep changes small and focused. If changing Chinese user-facing guidance in `README.md`, update the matching English guidance in `README.en.md` when practical.

## Safety Boundaries

- Never commit secrets, `auth.json`, API keys, OAuth tokens, private keys, browser profiles, local credential stores, or generated auth files.
- Repairs that stop, uninstall, reinstall, repackage, or relaunch Codex Desktop must be run from an external executor such as Windows PowerShell or the VS Code Codex extension, not from the Codex Desktop session being repaired.
- Treat the external-executor requirement as a handoff boundary, not as permission for the active Desktop session to start or background a destructive worker. The active Desktop session may perform only read-only triage and non-live candidate preparation; it must not invoke `-Install`, `Remove-AppxPackage`, `Add-AppxPackage`, `Stop-CodexDesktopProcesses`, or an equivalent replacement/relaunch action against a registered Desktop package.
- Before any external deployment is presented to the user, independently validate the candidate MSIX signature and certificate trust/deployment prerequisites, preserve a recoverable package or installation path, and write bounded `READY_FOR_INSTALL`, `READY`, `NEEDS_ACTION`, or `FAILED` status. A successful signing command or ASAR dry run is not deployment proof.
- Present the exact external command, expected impact, rollback path, and preflight result to the user. Run the destructive deployment only after the user explicitly confirms that specific action; on failure, restore the prior package and record `FAILED` instead of leaving Desktop unregistered.
- The Desktop state target is `$env:USERPROFILE\.codex`. An isolated CLI home such as `$env:USERPROFILE\.codex-cli` is not Desktop state.
- Do not set a global `CODEX_HOME`, and do not copy or migrate Desktop state into an isolated CLI home unless a user explicitly requests a separate migration plan.

## Verification

- For documentation-only changes, run `git diff --check`.
- For PowerShell script changes, parse the edited scripts with:

```powershell
Get-ChildItem -LiteralPath scripts -Filter *.ps1 | ForEach-Object {
  $null = [scriptblock]::Create((Get-Content -Raw -LiteralPath $_.FullName))
}
```

- For CommonJS script changes, run `node --check` on each edited `.cjs` file.
- Report exactly which checks were run and whether they passed.
