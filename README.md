# scripts

Setup shell scripts for Lumivero apps, published via **GitHub Pages** and run
remotely by piping into a shell. `lumivero.github.io/scripts/` maps directly to
the root of this repo — there is no build step, so whatever is committed at the
root is what gets served and executed.

## Available scripts

| App | Command |
| --- | --- |
| Lumivero API | `curl -fsSL https://lumivero.github.io/scripts/lumivero-api_setup.sh \| sh` |

## Adding a script for another app

This repository hosts one setup script per app. Scripts follow the naming
convention:

```
<app>_setup.sh
```

and are served at `https://lumivero.github.io/scripts/<app>_setup.sh`. To add a
setup script for another app, commit a new `<app>_setup.sh` at the repo root and
add a row to the table above. Each script must stay self-contained and POSIX-sh
clean (see [`CLAUDE.md`](CLAUDE.md) for the constraints that follow from the
`curl … | sh` delivery model).
