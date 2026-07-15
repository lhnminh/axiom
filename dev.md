# Axiom MVP Specification

## Overview

Axiom is a macOS application that helps students read textbooks and research papers more effectively.

Users import a folder of PDFs into the app. While they read, an AI companion ("Pet") proactively highlights important information directly within the original PDF. A persistent AI chat is available alongside the document for deeper exploration.

The pet provides personality and visual feedback, while the AI performs the underlying analysis.

---

# Layout

```
+---------------------------------------------------------------+
| Sidebar        |            PDF Viewer          |   AI Chat    |
|                |                               |              |
| 📁 Folder      |                               |              |
|  ├─ Paper A    |                               |              |
|  ├─ Paper B    |                               |              |
|  └─ Notes.pdf  |                               |              |
|                |                               |              |
+---------------------------------------------------------------+
```

## Left Sidebar

- Browse PDFs inside one imported folder
- Simple file tree
- Open documents

## Center

- Original PDF viewer
- No document conversion
- Users read directly from the source PDF

## Right

- Persistent AI chat
- Context strategy is still under discussion

---

# Reading Experience

The application is designed to feel passive and natural.

1. User imports a folder.
2. User opens a PDF.
3. User reads normally.
4. AI analyzes the current page.
5. The pet flies across the page.
6. Important sentences are highlighted.
7. User continues reading.

No manual activation is required.

---

# AI Pet

The pet is inspired by Codex Pets.

For the MVP it has:

- Fixed appearance
- Decorative personality
- AI-driven behaviors
- Can be dragged
- Can be dismissed
- Can be disabled

The pet itself is **not** the AI.

Instead, it visualizes AI actions.

```
AI analyzes page
        ↓
Pet flies across page
        ↓
Highlights appear
```

---

# Highlighting

Current behavior:

- Automatically highlight important sentences
- Display temporary overlay highlights
- Highlights remain for the current session
- Results may be cached as metadata to avoid repeated processing

Highlights currently have **no interaction** when clicked.

Future possibilities include:

- Definitions
- Equation explanations
- Figures
- Cross-document references
- Quick facts
- Code generation from mathematical notation

---

# Manual Highlighting

Users can create their own highlights.

User highlights and AI highlights are separate.

---

# AI Processing

Still under discussion.

Current direction:

- Process pages as they are viewed
- Cache AI-generated metadata

Potential cached data:

- Highlight locations
- Summary
- Processed status

---

# AI Chat

Persistent chat on the right side.

Context is still undecided.

Possible modes:

- Current page
- Entire document
- Entire imported folder (RAG)

---

# References

Not included in the MVP.

Possible future additions:

- Page citations
- External references
- Cross-document navigation

---

# Safeguards

To avoid distracting users:

- Prevent duplicate highlights
- Avoid repeatedly highlighting the same sentence
- Prevent excessive highlighting on a page
- Avoid triggering while users are actively scrolling

Exact behavior will be refined during implementation.

---

# User Flow

```
Import Folder
      ↓
Browse PDFs
      ↓
Open Document
      ↓
Read Normally
      ↓
AI analyzes current page
      ↓
Pet flies across page
      ↓
Important sentences highlighted
      ↓
Continue reading
      ↓
Ask questions in AI Chat
```

---

# Future Ideas

Not part of the MVP.

- Equation explanations
- Figure explanations
- Mathematical notation → executable code
- Cross-document reasoning
- Reading progress tracking
- Flashcards
- Quiz generation
- Multiple pet personalities
- Adaptive highlighting based on reading behavior

---

# MVP Scope

## Included

- Import a folder of PDFs
- File browser
- Original PDF viewer
- Persistent AI chat
- Animated AI pet
- Automatic highlighting of important sentences
- Session-level caching
- User-created highlights
- Drag, dismiss, and disable the pet

## Not Included

- Reading behavior analysis
- Struggle detection
- Interactive highlights
- External references
- Cross-document retrieval
- Flashcards
- Quiz generation
- Multiple pets
- Advanced personalization

---

# Design Principles

- Reading should never be interrupted.
- The pet should feel helpful, not distracting.
- AI should proactively surface important information.
- The original PDF remains the source of truth.
- The experience should feel lightweight, magical, and intuitive.