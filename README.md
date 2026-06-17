# PantryHub

**Cook what you already have. Waste less.**

Roughly a third of the food we buy ends up in the bin — not because people want
to waste it, but because two things are genuinely hard: remembering everything
that's actually in your kitchen, and deciding what to cook with it before it
goes off.

PantryHub closes that gap. You capture your whole pantry in seconds, and an AI
chef turns it into meals you can make *right now* — curating a fresh feed every
day and then cooking alongside you, by text or by voice. When you're done, it
quietly updates your pantry so tomorrow's suggestions stay honest.

---

## The idea in one loop

```
        ┌──────────────────────────────────────────────────────┐
        │                                                      │
        ▼                                                      │
   CAPTURE  ──▶  CURATE  ──▶  COOK  ──▶  DEDUCT  ──────────────┘
   what you      a daily      with an     what you used,
   have, fast    feed you     AI chef     so the loop
   (photo /      can actually (text or    stays honest
   barcode /     make today   voice)
   voice)
```

Every step feeds the next. The less friction there is in capturing your pantry,
the better the curation; the more honest the deduction, the more the daily feed
nudges you toward the things that are about to expire.

---

## What makes it good

### 🧺 Capture your pantry without typing
Adding food is the make-or-break of any pantry app, so there are four low-effort
ways in — all funnelling into one review screen:

- **Photo / gallery** — snap a shelf, a product, or a **receipt** (one photo can
  add a whole shop). A vision model reads off each item: name, brand, size.
- **Barcode** — point at packaged goods; details are pulled from the open
  [Open Food Facts](https://world.openfoodfacts.org) database.
- **Voice** — just say what you bought; it's cleaned up, spelled correctly, and
  split into items.

Anything the AI isn't sure about is flagged so you can fix it in a tap. New items
default sensibly (a full container, an estimated expiry you can confirm), and the
editor adapts to the product — a draggable jar for liquids, a piece counter for
eggs and fruit.

### 📦 It understands quantities and dates, not just names
PantryHub doesn't only know you *have rice* — it tracks roughly **how much**
(per-container fullness, normalised to canonical units) and **when it expires**.
That's what powers low-stock and expiring-soon flags, and honest "you're short"
warnings while cooking.

### 🍳 A daily feed matched to *your* kitchen
Each night a curator builds four meals — breakfast, lunch, dinner, snacks — and
ranks each by how much of it you can make from what you own. It suggests
substitutions for the bits you're missing, grounds its choices in live web
search, and leans toward ingredients that are about to expire.

### 🤖 Cook with an AI chef — text or live voice
Pick a recipe and a chef walks you through it:

- scales every ingredient and step to **who's eating** (adults and kids),
- warns you up front when you're short on something and offers to scale down or
  substitute,
- runs **kitchen timers** with lock-screen notifications,
- breaks tricky steps into clear micro-steps.

The voice chef is a real-time conversation — talk to it while your hands are
busy.

### 🧠 One brain across text and voice (the agentic core)
This is the part that makes the cooking experience feel seamless. The text chef
and the voice chef aren't two separate features — they **share a single cook
session** through a single-writer **ledger** for the recipe and its steps. The
chef is a tool-using agent: it reads your live pantry, edits the recipe and steps
on the fly, sets timers, and reconciles a step checklist that is the **single
source of truth**. So you can start a dish by text, switch to voice mid-cook, and
nothing falls out of sync.

### ♻️ The payoff: less waste
Finish a recipe and PantryHub deducts what you used from your pantry. Your stock
goes down, your next feed updates, and the ingredients creeping toward their
expiry date get nudged to the top. That's the whole point — a kitchen that keeps
itself honest.

---

## Under the hood

For anyone reading the code, here's the shape of it:

- **iOS app** — native **SwiftUI** (Xcode 16, iOS 17+). Multimodal capture uses
  the system camera, VisionKit for barcodes, and on-device speech recognition.
- **Data & logic** — **Supabase** (Postgres + Deno edge functions) is the single
  source of truth for the pantry, recipes, cook sessions, and chat history.
- **The AI** — Google's **Gemini** models behind a small, keyless server layer:
  a text proxy for the curator and chefs, and a live WebSocket bridge for voice.
  The app never holds a model key.
- **Design patterns worth a look:**
  - a **single-writer ledger** so the text and voice chefs can edit one shared
    recipe safely,
  - **quantity normalisation** (everything reduced to canonical g / ml / piece)
    that makes serving-scaling and shortfall maths reliable,
  - **per-user nightly curation** that runs at each user's *local* midnight, with
    web-grounded validation of the recipes.

### Repository layout

```
PantryHub/          The SwiftUI app
  AddPantryView      ·  the four-door capture hub
  PhotoIntakeView / BarcodeIntakeView / VoiceIntakeView
  IntakeReviewView   ·  the shared review-and-confirm list
  IngredientDetailView ·  the shared item editor
  Models / AppStore / BackendService / PantryIntakeService
  ...                ·  recipe feed, chefs, timers, Kitchen, settings

supabase/
  functions/         Deno edge functions (curator, chefs, pantry, intake, …)
  migrations/        SQL schema history

cloud-run/
  vertex-proxy/      keyless text proxy to Gemini
  voice-chef/        live voice bridge (Gemini Live)
```

---

## Running it

1. Open `PantryHub.xcodeproj` in **Xcode 16**.
2. Copy the secrets template:
   `cp PantryHub/Config/Secrets.example.plist PantryHub/Config/Secrets.plist`
3. Build to a **real device** — the camera, barcode scanner, and microphone
   don't work in the simulator.

The backend (Supabase functions + the Cloud Run services) is already deployed.

> **Secrets never live in this repo.** `Secrets.plist` and server `.env` files
> are git-ignored; only their `.example` templates are tracked. The Supabase
> anon key and Clerk publishable key shipped in the app are public by design.

---

*The front end is essentially complete and the backend is live — PantryHub is an
actively evolving project.*
