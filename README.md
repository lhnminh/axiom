# EducationOS PDF Reader Prototype

A native macOS prototype for reading PDFs and automatically highlighting likely-important text.

## What it does

- Opens local PDF files with Apple's PDFKit.
- Extracts page text locally.
- Uses Gemini or OpenAI to identify definitions, theorems, lemmas, corollaries, equations, notation, and core concepts.
- Adds yellow highlight annotations directly on top of important text in the PDF view.
- Keeps a right sidebar with candidate metadata for future controls.

PDF text itself is not rewritten in-place. This prototype adds visual yellow PDF annotations over text that AI, or the fallback heuristic, considers important.

## Run it

```bash
swift run EducationOSPDFReader
```

Then choose **Open PDF** or press `Command-O`.

This SwiftPM prototype is not packaged as a Finder-registered `.app` yet. Double-clicking a PDF in Finder will still open your default PDF app. For now, launch this prototype first, then open the PDF from inside the app.

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

If the provider API key is missing or the API request fails, the app falls back to the local heuristic and says so in the toolbar/sidebar.

To use OpenAI instead:

```env
AI_PROVIDER=openai
OPENAI_API_KEY=your_openai_api_key_here
OPENAI_MODEL=gpt-5.2
```

## Prototype heuristic

The current analyzer favors sentences that:

- include cue words like `important`, `therefore`, `definition`, `evidence`, or `critical`
- have a useful academic sentence length
- contain punctuation such as colons or semicolons
- include capitalized terms that look like concepts or named entities

This fallback is intentionally local and dependency-free. The primary path is now AI semantic highlighting.

## Debug logging

When running from the project folder, MathPilot writes logs to:

```text
mathpilot.log
```

The same logs also print in the terminal used for `swift run`. Logs include provider selection, model name, request status, response snippets, JSON decode failures, fallback reasons, and highlight counts. API keys are redacted.
