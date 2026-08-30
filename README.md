# 📚 Prompt Collection for RemNote

A native macOS application built with **SwiftUI** designed to manage, customize, and rapidly copy AI prompts tailored specifically for your **RemNote** study workflow.

The app features a built-in local HTTP server that communicates with RemNote in real-time. It automatically inserts content from your currently active flashcard (front, back, document path, and images) directly into your AI prompts.
<img width="1393" height="872" alt="image" src="https://github.com/user-attachments/assets/bb39da45-0dcd-4c1b-9d92-ecad250cb360" />

---

## ✨ Features

- **⚡ RemNote Live Sync:**
  - Integrated local lightweight server (`Port 8000`) that listens for card updates from RemNote.
  - Sidebar live preview showing the currently selected flashcard's front text and attached images.
  - One-click copy for attached images directly to the macOS clipboard as PNGs.
- **🏷️ Smart Dynamic Placeholders:**
  - Automatic replacement of flashcard tags (e.g., `/Karte/`, `/Flashcard/`, `/Vorderseite/`, `/Front/`, `/Pfad/`, `/Path/`).
  - **Interactive Variables (`{...}`):** Prompts containing custom placeholders (e.g., `{Topic}`, `{Language}`) automatically open a pop-up sheet to quickly fill in the values before copying.
- **📂 Category & Prompt Management:**
  - Organize prompts by custom categories (e.g., *Vocabulary*, *Flashcards*, *Multiple Choice*, *Lecture Slides*).
  - Easily reorder categories and prompts (Move Up / Down).
  - Built-in SF Symbols icon picker for categories.
- **✏️ Inline Prompt Editor:**
  - Edit prompt templates directly inside collapsible card views with auto-saving.
- **🔍 Intelligent Search:**
  - Distinguishes between matches found in the title and matches inside the prompt body.
  - Automatically selects, opens, and scrolls to the matched prompt.
- **📋 Batch Export & Markdown Copy:**
  - Export and copy all prompts across all categories as cleanly formatted Markdown with a single click.
  - 100% offline and local persistence via `UserDefaults`.

---

## 🧩 Supported Placeholders

You can use the following dynamic placeholders in your prompt templates:

| Placeholder | Description |
| :--- | :--- |
| `/Karte/` or `/Flashcard/` | Inserts the complete flashcard (Path, Front, and Back). |
| `/Vorderseite/` or `/Front/` | Inserts only the front text of the card. |
| `/Rückseite/` or `/Back/` | Inserts only the back text of the card. |
| `/Pfad/` or `/Path/` | Inserts the document / folder hierarchy path. |
| `/Liste/` or `/List/` | Inserts the bullet list or items on the card. |
| `/Bild/` or `/Image/` | Inserts a note indicating attached images. |
| `{Variable Name}` | Opens an interactive sheet to fill in custom values before copying. |

---

## 🛠️ Tech Stack & Architecture

- **Language:** Swift 5.9+ / 6.0
- **Frameworks:** SwiftUI, Network (`NWListener` / `NWConnection`), AppKit, Combine
- **Local Server:** HTTP server running on `http://127.0.0.1:8000` (supports POST & OPTIONS with CORS enabled).

### RemNote Inbound JSON Payload

```json
{
  "cardId": "string",
  "remId": "string",
  "front": "Front of the flashcard",
  "back": "Back of the flashcard",
  "path": "Folder > Document",
  "images": ["data:image/png;base64,..."],
  "timestamp": 1725000000
}
```

---

## 🚀 Getting Started

### Prerequisites
- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR-USERNAME/PromtsammlungFuerRemNote.git
   ```
2. Open `PromtsammlungFürRemNote.xcodeproj` in **Xcode**.
3. Build and run the project (`Cmd + R`).

---

## 📄 License

This project is licensed under the **MIT License** – see the [LICENSE](LICENSE) file for details.
