# TrueOG Gitea

TrueOG Network's fork of [Gitea](https://github.com/go-gitea/gitea), the self-hosted Git service that runs
[git.trueog.net](https://git.trueog.net). It is Gitea **28.3.0** (upstream tag `v28.3.0`) plus TrueOG's
customizations in [`trueog/`](trueog/): templates and assets that Gitea loads from its `custom/` directory,
and a few small jobs and one small service beside it. Gitea runs under OpenRC, so the fork ships OpenRC
service files instead of systemd's and leaves out Gitea's systemd integration; otherwise Gitea's code is
unchanged.

## Differences from Gitea

- **Landing page:** a TrueOG page at `/` for visitors (and `/?home=1` when signed in), with the TrueOG
  title, contribution and sign-in buttons, information cards, and live statistics (public repositories,
  open pull requests, open issues) that need no JavaScript.
- **Sign-in page:** in the landing page's style, with "Sign in with GitHub" and "Sign in as staff".
- **Navbar and footer:** a Minecraft-lambda Home link and a Dashboard link for signed-in users; a
  Monocraft footer with the TrueOG motto.
- **Public indexes:** `/pulls?state=all|open|closed` and `/issues?state=all|open|closed` list every public
  pull request and issue for anyone, signed in or not (All/Open/Closed tabs, "Hide personal
  repositories", newest activity first, the All tab 50 per page, refreshed every 5 minutes). Bare `/pulls`
  and `/issues` remain Gitea's dashboards.
- **Contribution choosers:** `/contribute/pull-request` and `/contribute/bug-report` lead to the chosen
  repository's pull request, fork or issue form.
- **Fork banner:** the branches of a non-archived fork show "This branch is N commits ahead of, M commits behind
  <upstream>", like GitHub, with links to both diffs. The counts are worked out live by a small local
  service (`trueog/trueog-divergence.py`) and only for visitors whom Gitea lets read both repositories'
  code. When the upstream is not open to everyone (private, under a limited or private owner, or with its
  Code tab disabled), the banner appears only when Gitea's own would. Gitea's "Sync fork" button keeps
  its usual rule.
- **404 page:** Gitea's "404 Not Found" page with a picture.
- **Branding:** TrueOG logo, favicons and web manifest; the Monocraft font.
- **OpenRC instead of systemd:** [`contrib/service/openrc/`](contrib/service/openrc/) holds the init script
  and conf.d file git.trueog.net uses (supervise-daemon, no Docker); Gitea's systemd unit is removed, and
  `contrib/upgrade.sh` uses `rc-service` by default. The Gitea binary no longer speaks systemd's notify
  protocol (`NOTIFY_SOCKET`, watchdog) or accepts systemd socket activation (`LISTEN_FDS`). What OpenRC
  relies on is unchanged: SIGTERM stops Gitea gracefully, SIGUSR1 reopens its logs, and Gitea's own
  graceful restart on SIGHUP still hands its sockets to the new process (as `GITEA_LISTEN_FDS`), so a
  SIGHUP restart cannot hand over between Gitea's official binary and a build of this fork; switch
  between them with `rc-service gitea restart`.
- **Repository policy:** `.gitea/CODEOWNERS` asks TrueOG staff (Admins or Developers) for review.

Details and the deployment scripts: [`trueog/README.md`](trueog/README.md).

## Building

Requirements (from Gitea 28.3.0's `go.mod` and `package.json`): Go 1.27 (toolchain go1.27.3),
Node.js 22.18 or newer, pnpm 11 or newer, GNU Make and Git.

```sh
git clone https://git.trueog.net/trueog/gitea.git
cd gitea
TAGS="bindata" make build    # builds the frontend and backend into a single ./gitea binary
```

Add `sqlite sqlite_unlock_notify` to `TAGS` for SQLite support, as Gitea's release binaries do. Gitea's
[docs/build-setup.md](docs/build-setup.md) and [docs/build-source.md](docs/build-source.md) cover the
prerequisites and further options. The only TrueOG change in the binary is the removed systemd
integration; the look comes from `trueog/`, installed with `trueog/install-custom-templates.sh`.
git.trueog.net currently runs Gitea's official signed release binary with these customizations (its
systemd integration is inactive under OpenRC).

## Updating

This branch follows Gitea's release tags: a new release is taken by rebasing TrueOG's commits onto the
new tag. Do not use Gitea's "Sync fork" button here: it would merge upstream's development branch
(`main`), not a release.

## License

Gitea is MIT-licensed ([`LICENSE`](LICENSE)). TrueOG's additions are released under The Unlicense
([`trueog/LICENSE`](trueog/LICENSE)), except files adapted from Gitea or containing GitHub Octicons, which
stay MIT, and the Monocraft font (SIL Open Font License 1.1); see [`trueog/NOTICE.md`](trueog/NOTICE.md).
