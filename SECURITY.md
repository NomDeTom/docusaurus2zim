# Security policy

## Supported versions

The newest release of the current major version (today `v1`, the `v1` tag) gets security fixes. Older majors do not.

## Reporting a vulnerability

Report it privately through GitHub: the **Security** tab of this repository → **Report a vulnerability**. Please do not open a public issue for a security problem.

Say what you found, how to reproduce it and what it affects (the action, `build.sh`, `package.py`, or the `ghcr.io/nomdetom/docusaurus2zim` image). You will get an answer within a week. A confirmed problem is fixed in a new release, and credited in its notes unless you ask not to be.

## What this project runs

The action runs in your workflow, on your runner, with your workflow's permissions. It collects no data and sends nothing to its author. It downloads only from PyPI, the runner's Debian/Ubuntu mirrors, `ghcr.io` (the packaging image) and any hosts you list in `mirror_hosts`. The image is built from this repository's `Dockerfile` by its CI and published with the version tags of each release.
