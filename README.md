# Windows Server Manager

A small deployment manager for an always-on Windows host running several Dockerised
services. It **auto-discovers** sibling projects, keeps them up to date from their GitHub
branches, and refuses to do so when that would overwrite work.

Written in PowerShell, about 300 lines. It exists because unattended deployment has a
short list of ways to go badly wrong, and each one needs an explicit guard.

> 中文文档见 [README.zh-CN.md](./README.zh-CN.md)。

---

## Layout

```
C:\Users\<user>\Server\
├── manager\           this repository
├── infohub\           a service
└── another-project\   any other service
```

Any sibling directory that contains **both** a `.git` directory and a Compose file
(`compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.yaml`) is picked up
automatically. Adding a service needs no change to the manager.

## Install

Clone into `Server\manager`, then double-click `create-desktop-shortcut.cmd`. The manager
updates itself on launch, and falls back to the installed version when offline.

## Menu

View project and container status · pull and redeploy one project · start / stop / restart
· tail the last 100 log lines · update and deploy everything · enable or disable background
auto-deployment.

Each deployment passes the project's current Git commit SHA to Docker, so a service that
supports it can report the exact running version on its health page.

## Automatic deployment

Enabled once from the menu; starts with the user's Windows session and polls each sibling
project's branch every five minutes. New upstream commits trigger a fast-forward pull and
a container rebuild. Locking the screen does not interrupt it.

**What it refuses to do.** If a project has uncommitted local changes, or its branch has
diverged from the remote, that project is **skipped** — no pull, no rebuild, nothing
overwritten. The skip is logged.

## Guards

Each of these is here because it is a specific way an unattended loop can fail:

| Guard | Failure it prevents |
|---|---|
| Fast-forward only, skip on divergence or dirty tree | Silently discarding work that only exists on the host |
| Named mutex, with abandoned-mutex handling | Two runs deploying at once, and a permanent deadlock if a holder dies |
| `GIT_TERMINAL_PROMPT=0` | A credential prompt hanging the loop forever with no terminal attached |
| Log rotation at 2 MB | Filling the disk over months of running |
| PID file | Not knowing whether the loop is alive |
| Docker readiness check | Thrashing while Docker Desktop is still starting |

Logs are written to `manager\logs\auto-deploy.log`.

## Boundaries

Project data and each service's `.env` stay in the project directory; the manager never
touches them, and stopping a service does not delete its data. The manager only ever
performs fast-forward pulls and Compose rebuilds — it has no path that rewrites history or
force-updates a working tree.

It assumes the Windows user stays logged in, and that Docker Desktop is running.
