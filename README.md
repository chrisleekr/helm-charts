# Chris' Helm Charts

This repository contains the Helm charts that I use to deploy my applications. This functionality is in beta and is subject to change. The code is provided as-is with no warranties.

## Usage

[Helm](https://helm.sh) must be installed to use the charts.
Please refer to Helm's [documentation](https://helm.sh/docs/) to get started.

Once Helm is set up properly, add the repository as follows:

```console
helm repo add chrisleekr https://chrisleekr.github.io/helm-charts
```

## Automation

The `Sync github-app release` workflow (`.github/workflows/github-app-sync.yml`) keeps the
`github-app` chart aligned with [chrisleekr/github-app](https://github.com/chrisleekr/github-app)
releases. It is run manually via `workflow_dispatch` (for example after a github-app release),
and when the chart's `appVersion` is behind it opens a PR that bumps `Chart.yaml`. When the app's
env-var surface changed between releases it also runs `claude-code-action` to reconcile
`values.yaml` / `configmap.yaml` / `secret.yaml`; otherwise the PR is a plain version bump with
no LLM step. Every sync PR is gated by the `env-parity` check in `lint.yml`, which asserts the
chart's env keys match the app's published `env-contract.json` (with
`charts/github-app/.env-contract-ignore` for intentional omissions).

Required repository secrets:

- `RELEASE_TOKEN` — a PAT used to open the sync PR so `lint.yml` runs on it (a PR opened by the
  default `GITHUB_TOKEN` would not trigger `pull_request` workflows).
- `CLAUDE_CODE_OAUTH_TOKEN` — used only by the env-reconciliation step. If unset, env-surface
  changes are not auto-reconciled and must be handled by hand.
