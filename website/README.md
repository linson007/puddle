# Puddle product site

A responsive, buildless product website for the Puddle macOS application.

## Preview

Run from this directory:

```sh
python3 -m http.server 4173 --directory dist --bind 127.0.0.1
```

Open `http://127.0.0.1:4173`. No dependency installation or build is required.

## Content and interactions

- Interactive sample workspace with Today, chat, tasks, calendar, mail, meetings,
  Developer, Knowledge and Memory views. Demo tasks can be toggled; data is held
  only in page memory.
- Searchable feature directory with category filters, expandable details and
  an empty state.
- Responsive navigation, installation-command copy control and FAQ disclosures.
- All app data shown on the website is illustrative. The site does not connect
  to accounts, perform Puddle actions or run a model.
- Product claims and requirements come from the repository README and feature
  guide. Revisit these when the application changes.

Source files are in `dist/`. The hosting identity is in `.openai/hosting.json`.
The site uses Google Fonts with system-font fallbacks; no analytics or tracking
scripts are included. GitHub links use `https://github.com/linson007/puddle`.
