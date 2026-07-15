# Axiom MVP Roadmap (Hackathon)

## Vision

**Axiom** is an AI-powered reading environment for mathematics that helps students understand complex material without replacing the learning process.

Instead of chatting with a PDF, Axiom understands an entire course and augments the reading experience with contextual AI.

---

# Demo Goal (3 Minutes)

Demonstrate how AI can transform static lecture notes into an interactive mathematical learning environment.

---

# MVP Features

## 1. Course Import

The student drags an entire course folder into Axiom.

```
Real Analysis/

├── Lecture 1.pdf
├── Lecture 2.pdf
├── Lecture 3.pdf
├── Homework 1.pdf
└── Midterm Review.pdf
```

Axiom indexes every document and prepares the course for reading.

---

## 2. AI Course Processing

Instead of treating every PDF independently, Axiom builds semantic metadata across the entire course.

Extract:

- Definitions
- Theorems
- Lemmas
- Corollaries
- Equations
- Mathematical symbols
- References
- Relationships between concepts

Example:

```
Measure Space

Introduced:
Lecture 2

Referenced:
Lecture 4
Homework 1
```

This creates a structured knowledge base that powers the reading experience.

---

## 3. AI Reading Mode (Core Demo)

Students open any lecture note and read normally.

As they read, Axiom automatically:

- Highlights important mathematical concepts
- Identifies definitions and theorems
- Recognizes equations and notation
- Provides contextual explanations
- Links related concepts from previous lectures
- Generates computational intuition for mathematical notation

Example:

```
∀ ε > 0
∃ δ > 0
```

becomes an intuitive explanation or pseudocode-style interpretation to help students understand the underlying idea rather than simply reading abstract symbols.

The goal is **not** to solve mathematics, but to make mathematical notation easier to reason about.

---

# Demo Flow

### Step 1

Import a folder containing an entire mathematics course.

↓

### Step 2

AI parses the documents and builds semantic metadata.

↓

### Step 3

Open a lecture note.

↓

### Step 4

Definitions, theorems, and equations are automatically highlighted.

↓

### Step 5

Click a highlighted concept to see:

- Plain-English explanation
- Related concepts
- Where it first appeared
- Computational intuition for the notation

---

# Core Philosophy

AI should **empower mathematical thinking**, not replace it.

Instead of giving students answers, Axiom helps them understand what they're reading.