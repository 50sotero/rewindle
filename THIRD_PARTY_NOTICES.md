# Third-party notices

Rewindle is an independent community project and is not affiliated with or
endorsed by the Restic project, the Python Software Foundation, Beautiful UI,
Motion, or any other upstream project listed here.

Release bundles redistribute these pinned upstream components:

- **Restic 0.19.1**, licensed under the BSD 2-Clause License. The full license
  is in [`licenses/RESTIC.txt`](licenses/RESTIC.txt).
- **Python 3.14.6 embeddable distribution**, licensed under the Python Software
  Foundation License and other notices included by Python. The build copies
  Python's complete `LICENSE.txt` into every release bundle as
  `licenses/PYTHON.txt`.

Exact upstream URLs and SHA-256 values are recorded in
[`dependencies.json`](dependencies.json). Neither dependency binary is stored
in this Git repository; the release builder downloads immutable versioned
archives and rejects any checksum mismatch.

## Dashboard

The Windows dashboard uses the following source and packages. The dashboard
build copies the license file of every runtime web dependency into
`licenses/web-dependencies/` next to the executable and fails if one is
missing; Settings > About opens that folder.

- **Beautiful UI**, pinned at commit
  `ff0f74d62d8be9d89bcb735b3632e31a6ccf88dc` from
  [slev12397/beautiful-ui](https://github.com/slev12397/beautiful-ui), is used
  for the navigation, task-row, filter, loading, insight, context, and motion
  primitives. The reference site is [beautifului.dev](https://www.beautifului.dev/).
  The copied source and its MIT license are documented in
  [`src/dashboard/web/vendor/UPSTREAM.md`](src/dashboard/web/vendor/UPSTREAM.md)
  and `src/dashboard/web/vendor/BEAUTIFULUI-MIT-LICENSE.txt`.
- **Motion 13.2.0**, an MIT-licensed React animation library, supplies page,
  stagger, and interaction motion. Its version is pinned by the web lockfile.
- **Liveline 0.0.7**, an MIT-licensed React chart library, renders the activity
  trend. Its version is pinned by the web lockfile.
- **React 19.3.0** (MIT), **lucide-react 0.577.0** (ISC),
  **tailwind-merge 3.7.0** (MIT), **clsx 2.1.1** (MIT),
  **class-variance-authority 0.7.1** (Apache-2.0) and **shadow-plugin 2.1.0**
  (MIT) are bundled into the web UI. Versions are pinned by the web lockfile.
- **Inter** and **JetBrains Mono** from Fontsource 5.3.0 are distributed under
  the SIL Open Font License 1.1. Their font notices remain in the web asset
  package and the generated brand assets.

The web UI preserves the upstream component structure and keyframes while
connecting the components to Rewindle state. Decorative motion does not
provide backup evidence and is disabled or reduced when the operating system
requests reduced motion.

## Microsoft Edge WebView2

The dashboard hosts its web UI in the Microsoft Edge WebView2 runtime. The
build downloads the **Microsoft.Web.WebView2 1.0.4191.47** SDK package from
NuGet, rejects it unless its SHA-256 matches the pinned value, and ships its
`Microsoft.Web.WebView2.Core.dll`, `Microsoft.Web.WebView2.Wpf.dll` and
`WebView2Loader.dll` with the dashboard. The SDK's `LICENSE.txt` and
`NOTICE.txt` are copied to `licenses/WebView2-LICENSE.txt` and
`licenses/WebView2-NOTICE.txt`. The WebView2 runtime itself is not
redistributed; the installer obtains Microsoft's signed bootstrapper when the
runtime is missing.
