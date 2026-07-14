# EducationOS PDF Reader Prototype

A native macOS textbook reader that extracts PDF metadata locally and highlights important text on demand.

## What it does

- Opens with a textbook library instead of immediately showing a file picker.
- Initializes the library from a selected folder and recursively discovers its PDFs.
- References local PDFs without copying or modifying the originals.
- Extracts and fingerprints every page locally with PDFKit when a textbook is added.
- Uses Gemini or OpenAI to identify definitions, theorems, lemmas, corollaries, equations, notation, and core concepts.
- Calls AI only for the current page after the reader scrolls to it.
- Caches page results in SQLite so the same unchanged page is not analyzed twice.
- Adds yellow highlight annotations directly on top of important text and keeps the right sidebar.

PDF text itself is not rewritten in-place. This prototype adds visual yellow PDF annotations over text that the configured AI considers important.

## Run it

```bash
swift run EducationOSPDFReader
```

Then choose **Add Folder** or press `Command-O`, and select a folder containing textbook PDFs. Local page metadata is extracted without AI. Open a textbook and pause on a page to trigger that page's AI highlighting.

This SwiftPM prototype is not packaged as a Finder-registered `.app` yet. Double-clicking a PDF in Finder will still open your default PDF app.

## AI setup

To enable AI semantic highlighting, create a local `.env` file from the example:

```bash
cp .env.example .env
```

Then edit `.env`:

```env
AI_PROVIDER=gemini
GEMINI_API_KEY=your_gemini_api_key_here
GEMINI_MODEL=gemini-3.5-flash
```

After that, run normally with `swift run EducationOSPDFReader`.

Shell environment variables still work and override `.env` values.

If the provider API key is missing, local metadata extraction still works and the reader explains why AI highlighting is unavailable. Failed pages can be retried independently.

To use OpenAI instead:

```env
AI_PROVIDER=openai
OPENAI_API_KEY=your_openai_api_key_here
OPENAI_MODEL=gpt-5.2
```

## Metadata storage

MathPilot stores textbook, page, highlight, concept, and analysis-job metadata in:

```text
~/Library/Application Support/MathPilot/mathpilot.sqlite3
```

The original PDFs remain in their existing filesystem locations.

## Verification

Run the non-GUI fixture and cache checks with:

```bash
swift run EducationOSPDFReader --verify
```

## Debug logging

When running from the project folder, MathPilot writes logs to:

```text
mathpilot.log
```

The same logs also print in the terminal used for `swift run`. Logs include provider selection, model name, request status, response snippets, JSON decode failures, fallback reasons, and highlight counts. API keys are redacted.
