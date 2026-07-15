# Uninstall Axiom Prototype

Axiom currently runs through Swift Package Manager. It is not installed as a system application and does not modify imported PDF files.

## 1. Quit Axiom

Quit the running app with `Command-Q` before removing its data.

## 2. Remove Axiom metadata

The textbook library, extracted page text, cached AI highlights, concepts, and file references are stored under:

```text
~/Library/Application Support/Axiom/
```

Remove that directory with:

```bash
rm -rf "$HOME/Library/Application Support/Axiom"
```

This also removes `axiom.sqlite3` and its `-wal` and `-shm` companion files. It does not remove or modify the original PDFs.

If you used the previous MathPilot prototype name on this Mac, remove the legacy metadata directory too:

```bash
rm -rf "$HOME/Library/Application Support/MathPilot"
```

## 3. Remove local project data

From the project directory, remove compiled build output and debug logs:

```bash
rm -rf .build
rm -f axiom.log axiom-last-*.json mathpilot.log mathpilot-last-*.json
```

Remove the local environment file if you no longer want the API key stored on this Mac:

```bash
rm -f .env
```

Deleting `.env` only removes the local copy. Revoke the API key from the Gemini or OpenAI provider dashboard if the key should no longer be usable anywhere.

## 4. Remove the source code

To remove Axiom completely, delete the project folder after completing the previous steps. The source folder can also be kept if you only want to reset the application and its metadata.

## Verify removal

This command should print `Axiom data removed`:

```bash
test ! -e "$HOME/Library/Application Support/Axiom" && echo "Axiom data removed"
```

Any textbooks previously referenced by Axiom remain in their original folders.
