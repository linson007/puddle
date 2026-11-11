# Puddle product site

A responsive, buildless product website for the Puddle macOS application.

## GitHub Pages

Visit [linson007.github.io/puddle](https://linson007.github.io/puddle/).

The repository's `Deploy website to GitHub Pages` workflow publishes only
`website/dist/` when those files change on `main`. It can also be run manually
from GitHub Actions. Repository Settings → Pages uses **GitHub Actions** as
the publishing source. Relative asset links support the `/puddle/` project path.

## Preview

Run from this directory:

```sh
python3 -m http.server 4173 --directory dist --bind 127.0.0.1
```

Open `http://127.0.0.1:4173`. No dependency installation or build is required.

## Content and interactions

- Interactive sample workspace with Today, chat, tasks, calendar, mail, meetings,
  Developer, Knowledge, Memory, Actions, Work Context, Browser, Routines, History,
  Connections and Settings views. The primary sidebar, More groups, pin controls,
  profile switching and screen headings follow the native app.
- Sample task capture, completion/reopening, Open/Waiting on/Completed filters,
  three daily priorities, matching task counts, editable meeting drafts,
  agenda/week switching, workspace search and an exact-content mail review.
  All changes are held only in page memory; reloading resets the workspace.
- Searchable feature directory with category filters, expandable details and
  an empty state.
- Responsive navigation, installation-command copy control and FAQ disclosures.
- All app data shown on the website is illustrative. The site does not connect
  to accounts, perform Puddle actions or run a model.
- Local AI copy presents Splash as a suggestion and supports any compatible local
  provider. Runtime installation, hardware requirements and model management belong
  to the chosen provider.
- Product claims and requirements come from the repository README and feature
  guide. Revisit these when the application changes.

Source files are in `dist/`. The hosting identity is in `.openai/hosting.json`.
`app.js` owns the feature directory and page controls; `preview.js` owns the
sample workspace. Keep its navigation and copy aligned with `PuddleSidebar`,
the store's sidebar groups, and the corresponding native views. On small screens
the sample navigation stacks above the workspace so controls remain readable.
The site uses Google Fonts with system-font fallbacks; no analytics or tracking
scripts are included. GitHub links use `https://github.com/linson007/puddle`.
