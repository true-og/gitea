# TrueOG customizations

Everything that makes [git.trueog.net](https://git.trueog.net) differ from a stock Gitea, exactly as
deployed: Gitea `custom/` overrides plus a few small jobs, one small service and configuration files that
run beside Gitea. Nothing in this folder modifies Gitea's own files; the fork's other changes (OpenRC
service files instead of systemd's, and the removal of Gitea's systemd integration) are outside it, see
the [repository README](../README.md).

| Path | What it is | Installed to |
| --- | --- | --- |
| `custom-templates/` | Template overrides: landing page, sign-in page, dashboard switch, navbar Home/Dashboard links, header/footer hooks, footer, fork banner, 404 page (see its README) | `/opt/gitea/custom/templates/` |
| `custom-public/` | CSS, JavaScript, Monocraft font, logo, favicons, web manifest (the 404 page's picture is not included; see [`NOTICE.md`](NOTICE.md)) | `/opt/gitea/custom/public/` |
| `gitea-homepage-stats` (+ `.cron`) | Every 5 minutes writes the landing page's statistics (public repositories, open pull requests, open issues) as a stylesheet, so the page needs no JavaScript | `/usr/local/sbin/`, `/etc/cron.d/` |
| `gitea-public-pages.py` (+ `.cron`) | Every 5 minutes generates the public pull request and issue indexes (`/pulls?state=…`, `/issues?state=…`) and the contribution choosers (`/contribute/pull-request`, `/contribute/bug-report`) from Gitea's anonymous API | `/usr/local/sbin/gitea-public-pages`, `/etc/cron.d/` |
| `trueog-divergence.py`, `trueog-divergence.initd` | Small local service (OpenRC, 127.0.0.1) that counts how many commits a fork branch is ahead of and behind its upstream, for the fork banner ("This branch is N commits ahead of, M commits behind …"); it answers only visitors whom Gitea lets read both repositories' code, handles at most 16 requests at once, and Nginx allows each visitor one request at a time and rate-limits it | `/usr/local/sbin/trueog-divergence`, `/etc/init.d/` |
| `gitea.nginx.conf`, `gitea-public-page-headers.nginx` | Nginx vhost: TLS, the public index and chooser routes, the fork banner's count route, their security headers | `/etc/nginx/` |
| `gitea-license-bundle`, `monocraft.LICENSE` | Rebuilds `/assets/licenses.txt` from the running Gitea's notices plus Monocraft's license | `/usr/local/sbin/`, `/usr/local/share/licenses/monocraft/` |
| `gitea.logrotate` | Log rotation for Gitea and the services above | `/etc/logrotate.d/gitea` |
| `install-custom-templates.sh` | Installs all of the above, restarts Gitea and the count service through OpenRC and verifies the result | run as root |
| [`../contrib/service/openrc/`](../contrib/service/openrc/) | Gitea's own OpenRC service (no Docker, no systemd): set up once when Gitea is installed, not by the scripts | `/etc/init.d/gitea`, `/etc/conf.d/gitea` |
| `upgrade-gitea.sh`, `UPGRADE.md` | Signed-binary upgrade with offline backup, rollback, and checks that every customization survives | run as root |
| `run-logged.sh` | Runs the two scripts above with their complete output saved to a log | run as root |
| `check-gitea-logs.sh` | Scans Gitea's logs for serious messages | |
| `trueog-gitea-fork.py` | Keeps this fork's `trueog/` in step with the deployed files: `check` lists the drift, `prepare` commits it in a work clone, `push` sends it as an ordinary fast-forward (see UPGRADE.md) | run as the operator |

## Deploying

The scripts expect this folder at `/home/system/gitea-upgrade` (`SRC=` at their top) and Gitea at
`/opt/gitea` with its configuration in `/var/lib/gitea/custom/conf/app.ini`; adjust those paths for
another host. Gitea itself runs as an OpenRC service, set up once as root from the repository root:

```sh
install -m 755 contrib/service/openrc/gitea /etc/init.d/gitea
install -m 644 contrib/service/openrc/gitea.confd /etc/conf.d/gitea
rc-update add gitea default
```

Then, as root, from this folder:

```sh
sh run-logged.sh install-custom-templates.sh        # customizations, jobs, Nginx routes, restart
sh run-logged.sh upgrade-gitea.sh check <version>   # read-only compatibility check of a new Gitea
sh run-logged.sh upgrade-gitea.sh apply <version>   # backup, switch, migrate, verify
```

`upgrade-gitea.sh` installs Gitea's official signed release binaries (verified against Gitea's release
key) and refuses an upgrade while any template TrueOG overrides changed upstream. [`UPGRADE.md`](UPGRADE.md)
lists every customization that must survive an upgrade.

## Licenses

The Unlicense, except files adapted from Gitea or containing GitHub Octicons (MIT) and the Monocraft font
(SIL Open Font License 1.1); see [`NOTICE.md`](NOTICE.md).
