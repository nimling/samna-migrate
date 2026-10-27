---
title: Testing and releasing
description: How the smig docker tests run, how a release moves the version and the latest tag, and how the setup action and the release workflow reach the private nimbody module.
visibility: hidden
tags: smig, tests, release, github action, private modules, nimbody
lastUpdated: true
---

## Docker tests

`just test-docker` builds a fake bookable Postgres, runs it on port 5436 and tears it down when the tests finish.

## Release

`just deploy` runs `sbump` with `--auto`. It writes the new version into `APP_VERSION` and into the default of the action's `smig-version` input, tags and pushes. The `latest` tag moves only after a green build, so a failed release leaves consumers on the previous version.

## Private module access

smig depends on nimbody, which is private, while samna-migrate is public, so the organisation secret does not reach this repository. It carries its own `DOCKER_PACKAGE_READ` secret.

1. The release workflow exposes the secret as `GH_REPO_TOKEN` to `git config --global url."https://${GH_REPO_TOKEN}@github.com/".insteadOf`, with `GOPRIVATE=github.com/nimling/*` at the workflow level, in the `test` and `build` jobs.

2. The GitHub Action installs smig with `go install ...@v<version>` on the consumer's runner. Its `Install smig` step runs the same `git config` when `GH_REPO_TOKEN` is set in the caller's env. samna_auth and bookable pass `GH_REPO_TOKEN: ${{ secrets.DOCKER_PACKAGE_READ }}` on the step; a consumer that leaves it out fails at `go install`.
