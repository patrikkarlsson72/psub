# PSUB Operator Guide Deck

This folder contains the reproducible source for the PSUB operator presentation.

## Files

- `slide_manifest.json` contains the slide-by-slide content.
- `build_psub_operator_guide.py` renders the final `.pptx`.
- `../screenshots/` contains the real UI captures used in the deck.

## Regenerate the deck

From the repository root:

```powershell
python .\output\presentation\source\build_psub_operator_guide.py
```

The generated file is:

```text
output\presentation\PSUB-Operator-Guide.pptx
```

## Screenshot set expected by the generator

- `output\presentation\screenshots\01-home-overview.png`
- `output\presentation\screenshots\02-prerequisites-panel.png`
- `output\presentation\screenshots\03-standard-build-settings.png`
- `output\presentation\screenshots\04-build-configuration.png`
- `output\presentation\screenshots\05-doc-page-prerequisites-guide.png`
- `output\presentation\screenshots\06-build-log-or-status.png`

The hero slide uses the repository asset at `assets\background.png`.

## Capture notes

This environment did not have Node or `npx`, so the Playwright skill path was blocked. The fallback is real browser capture through local tooling, preserving the same screenshot filenames so the deck remains reproducible.

The repo defaults to port `8080`, but this machine already had a conflicting registration on `http://localhost:8080/`. The captured screenshots were taken from an alternate local port with the same PSUB UI content.
