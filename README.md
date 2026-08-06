# Chris' Helm Charts

This repository contains the Helm charts that I use to deploy my applications. This functionality is in beta and is subject to change. The code is provided as-is with no warranties.

## Usage

[Helm](https://helm.sh) must be installed to use the charts. Please refer to Helm's [documentation](https://helm.sh/docs/) to get started.

Once Helm is set up properly, add the repository as follows:

```console
helm repo add chrisleekr https://chrisleekr.github.io/helm-charts
```

## Automation

The `Sync github-app release` workflow (`.github/workflows/github-app-sync.yml`) keeps the `github-app` chart aligned with [chrisleekr/github-app](https://github.com/chrisleekr/github-app) releases. It fires automatically when github-app cuts a stable release (its release-please pipeline sends a `repository_dispatch`), and can also be run manually via `workflow_dispatch` (blank input = latest release). When the chart's `appVersion` is behind it opens a PR that bumps `Chart.yaml`. When the app's env-var surface changed between releases it also runs `claude-code-action` to reconcile `values.yaml` / `configmap.yaml` / `secret.yaml`; otherwise the PR is a plain version bump with no LLM step. Every sync PR is gated by the env-parity check in `.github/workflows/lint-github-app.yml`, which `lint.yml` calls as the `github-app` job, and which asserts the chart's env keys match the app's published `env-contract.json` (with `charts/github-app/.env-contract-ignore` for intentional omissions).

The `omniroute` chart's `appVersion`, and the images the `binance-trading-bot` chart bundles, are tracked by [Renovate](https://docs.renovatebot.com) instead (`renovate.json`). The `binance-trading-bot` `appVersion` is not: `binance-trading-bot-sync.yml` owns that field so it can write the Artifact Hub changelog alongside it, and a second owner would race it into duplicate PRs. This requires the Renovate GitHub App to be installed on this repository — the config file alone does nothing, and if the App is absent nothing fails loudly, the chart just silently stops being updated. Upstream [diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute) is third-party, so `repository_dispatch` is unavailable and the release is polled weekly (`before 4am on Monday`); with the 3-day hold, a bump lands up to ~10 days after upstream publishes. A custom regex manager watches the `appVersion` in `charts/omniroute/Chart.yaml` (rather than `values.yaml`, whose `image.tag` is deliberately blank), and `bumpVersions` raises the chart `version` in the same PR so the `ct lint` version-increment gate passes. `appVersion` patch bumps auto-merge once the required `lint` check is green; minor and major bumps wait for review.

Every bump is held 3 days, measured from Docker Hub's `tag_last_pushed`, so an upstream release that is *deleted* within that window never lands. The hold does not protect against a tag being re-pushed to different content: the chart resolves the image by tag rather than digest, and a re-push restarts the 3-day clock. Note also that `lint` is a chart-level gate — it renders templates and checks the version increment, but never pulls or scans the upstream image, so a green check says nothing about the image contents.

Scope is deliberately narrow: `enabledManagers: ["custom.regex"]` disables every built-in manager, so Renovate sees **only what `customManagers` names explicitly** — the `appVersion` in `charts/omniroute/Chart.yaml`, plus the three images the binance chart bundles (`timescale/timescaledb`, `valkey/valkey`, `otel/opentelemetry-collector-contrib`) in its `values.yaml`. No other chart's `appVersion`, and no GitHub Actions or GitLab CI image reference, is monitored — the action SHAs in `.github/workflows/` and the container tags in `.gitlab/ci/` are manual bumps. Adding an image means adding a matcher; nothing is inherited. Widening coverage means adding the relevant manager (e.g. `github-actions`) to `enabledManagers`. Auto-merge is narrower still: the `automerge` rule is keyed to `matchDepNames: ["diegosouzapw/omniroute"]`, so every `binance-trading-bot` bump waits for review regardless of update type.
