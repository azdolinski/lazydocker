# binary mirror automation

This repository automatically downloads, unpacks/builds, and stores Linux binaries from upstream projects.

Currently supported projects:

- `lazydocker` from `https://github.com/jesseduffield/lazydocker`
- `htop` from `https://github.com/htop-dev/htop`
- `nano` from `https://git.savannah.gnu.org/git/nano.git`
- `docker-compose` from `https://github.com/docker/compose`
- `mc` from `https://github.com/MidnightCommander/mc`

## Purpose

The goal is to keep up-to-date, ready-to-use binaries in this repository without manual download, extraction, or build steps.

This repository is dedicated to binaries that are expected to run on Flatcar and Fedora systems.
Build configuration and linking decisions are made with Flatcar compatibility in mind.

## Output files

After each successful update for a tool named `toolname`, the repository contains:

- `binaries/toolname.vX.Y.Z`
- `binaries/toolname.vX.Y.Z.md5`
- `binaries/toolname.latest`
- `binaries/toolname.latest.md5`

Examples:

- `binaries/lazydocker.v0.24.4`
- `binaries/htop.v3.4.1`
- `binaries/nano.v8.6`
- `binaries/docker-compose.v2.39.4`

## Automation

The main updater workflow runs once a week on Sunday at 03:00 UTC and also supports manual run via GitHub Actions.

Current workflows:

- `Update all binaries weekly` (scheduled orchestrator that runs referenced subworkflows in sequence: lazydocker -> htop -> nano -> docker-compose -> mc)
- `Update lazydocker binary`
- `Update htop binary`
- `Update nano binary`
- `Update docker-compose binary`
- `Update mc binary`

## Download examples

You can download the latest binaries directly from this repository and save them without the `.latest` suffix:

```bash
wget -O lazydocker https://github.com/azdolinski/binaries/raw/refs/heads/main/binaries/lazydocker.latest
wget -O htop https://github.com/azdolinski/binaries/raw/refs/heads/main/binaries/htop.latest
wget -O nano https://github.com/azdolinski/binaries/raw/refs/heads/main/binaries/nano.latest
wget -O docker-compose https://github.com/azdolinski/binaries/raw/refs/heads/main/binaries/docker-compose.latest
wget -O mc https://github.com/azdolinski/binaries/raw/refs/heads/main/binaries/mc.latest
```

## Notes

- `lazydocker` is downloaded from release assets and stored as an unpacked executable.
- `htop` is downloaded from release source archive, built in CI, and then stored as an executable.
- `nano` is cloned from Savannah Git by latest tag, built in CI, and then stored as an executable.
- `docker-compose` is downloaded from release assets and stored as an unpacked executable.
- `mc` is built from the latest source release tarball and stored as an executable.
- Runtime compatibility target is Flatcar/Fedora; binaries are tuned to run there reliably.
- Each workflow commits only when files in `binaries/` changed.
- This structure is designed to be extended with more tools in future.
