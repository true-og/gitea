# Licenses of the TrueOG additions

Everything outside `trueog/` is [Gitea](https://github.com/go-gitea/gitea) 28.3.0, MIT-licensed
(see [`/LICENSE`](../LICENSE): Copyright (c) 2016 The Gitea Authors, Copyright (c) 2015 The Gogs Authors),
apart from TrueOG's own `README.md`, `.gitea/CODEOWNERS` and OpenRC service files in
`contrib/service/openrc/` (The Unlicense, like `trueog/`). TrueOG's changes to Gitea's files stay under
Gitea's MIT license: the line in `.gitattributes` that keeps `.gitea/CODEOWNERS` out of language
statistics, the OpenRC defaults in `contrib/upgrade.sh`, and the removal of systemd integration from
`modules/graceful/`, `modules/log/` and `cmd/web.go`.

Files in `trueog/` are released under **The Unlicense** ([`LICENSE`](LICENSE)) unless listed below. Files
that adapt material under another license keep that license, as the material requires.

## MIT (Gitea and GitHub Octicons)

These files adapt Gitea's templates or styling, or contain path data from GitHub's Octicons. They are
distributed under the MIT License, with Gitea's copyright notice (in [`/LICENSE`](../LICENSE)) and the
Octicons notice below. TrueOG's own changes in them are also offered under the same MIT terms.

| File | Adapted material |
| --- | --- |
| `custom-templates/home.tmpl` | Override of Gitea's `templates/home.tmpl` |
| `custom-templates/user/dashboard/dashboard.tmpl` | Override of Gitea's `templates/user/dashboard/dashboard.tmpl` (its else branch is Gitea's template) |
| `custom-templates/user/auth/signin.tmpl` | Override of Gitea's `templates/user/auth/signin.tmpl` |
| `custom-templates/user/auth/external_auth_methods.tmpl` | Override of Gitea's `templates/user/auth/external_auth_methods.tmpl` |
| `custom-templates/repo/code/upstream_diverging_info.tmpl` | Override of Gitea's `templates/repo/code/upstream_diverging_info.tmpl` (the fork banner) |
| `custom-templates/status/404.tmpl` | Override of Gitea's `templates/status/404.tmpl` |
| `custom-templates/base/footer_content.tmpl` | Override of Gitea's `templates/base/footer_content.tmpl` |
| `gitea-public-pages.py` | Navbar markup modelled on Gitea's `templates/base/head_navbar.tmpl`; Octicon SVG paths |
| `custom-public/assets/css/trueog-public.css` | Gitea's navbar geometry, spacing and colors (Gitea's computed values, including those of its Fomantic UI menus; no Fomantic UI source is copied) |
| `custom-public/assets/css/trueog-home.css` | The Octicon `arrow-up-right` path (an embedded SVG mask) |

The Octicon paths are taken from the copies bundled with Gitea 28.3.0 (`public/assets/img/svg/`), which
come from GitHub's [Octicons](https://github.com/primer/octicons); templates that only call Gitea's
`{{svg "octicon-…"}}` helper contain no Octicon data.

## SIL Open Font License 1.1 (Monocraft)

`custom-public/assets/fonts/Monocraft.woff2` is the Monocraft font by Idrees Hassan
(<https://github.com/IdreesInc/Monocraft>), licensed under the SIL Open Font License 1.1; its notice and
license are in [`monocraft.LICENSE`](monocraft.LICENSE), which must accompany the font. The font is not
sold on its own. `gitea-license-bundle` appends the same text to Gitea's served `/assets/licenses.txt`.

## TrueOG's own artwork (The Unlicense)

- The TrueOG logo, favicons and app icons (`custom-public/assets/img/`) are TrueOG Network's own artwork.
- The falling glyphs on the landing page (`custom-templates/trueog/glyphs.tmpl`) are original 5×7 pixel
  drawings made for TrueOG of the Standard Galactic Alphabet letterforms (the cipher alphabet known from
  Commander Keen and Minecraft's enchanting table). No font, texture or sprite from those games is copied.

## Not included

The TrueOG customizations also use Gitea's own `/assets/img/logo.svg` (served by Gitea, part of this MIT
repository); no other third-party images are included.

The picture on git.trueog.net's 404 page (`custom-public/assets/img/trueog-404.jpg`, a widely shared meme)
is not TrueOG's work and comes with no license, so it is not distributed here. Supply your own picture
under that name before running `install-custom-templates.sh`.

## GitHub Octicons license

```
MIT License

Copyright (c) 2026 GitHub Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
