# PantryHub

A pantry-and-cooking app for iPhone. You tell PantryHub what's in your kitchen,
and it gives you a daily feed of recipes you can actually make right now — then
walks you through cooking them with a text or voice chef that knows what you
have on hand.

The app is built natively in SwiftUI (Xcode 16, iOS 17+). The thinking happens
on a small backend: a Supabase database with Deno edge functions, plus two
Google Cloud Run services that talk to Google's Vertex AI for the language and
voice models.

---

## What it does

- **Pantry** — keep track of what you own. Add items four ways: snap or upload a
  photo (a shelf, a product, or a receipt), scan a barcode, or just say what you
  bought out loud. Everything lands in one review list before it's saved.
- **Recipes** — a feed of four meals (breakfast / lunch / dinner / snacks),
  freshly curated each night and ranked by how much of each recipe you can make
  from your current pantry. There's also an "Ask the Chef" chat that invents
  custom recipes on request.
- **Cooking** — a text chef and a live voice chef guide you step by step. They
  scale ingredients to the number of people you're cooking for, warn you when
  you're short on something, and run kitchen timers.
- **Kitchen** — recipes you've saved or already cooked.

When you finish cooking, the app deducts what you used from your pantry, so the
next day's recipe feed stays honest about what you can still make.

---

## How it's put together

```
┌────────────────────┐     HTTPS / WSS      ┌──────────────────────────┐
│  iOS app (SwiftUI) │ ───────────────────▶ │  Supabase                │
│  PantryHub/        │                      │   • Postgres (the data)  │
└────────────────────┘                      │   • Edge functions (Deno)│
          │                                 └────────────┬─────────────┘
          │ live voice (WebSocket)                       │ shared-secret
          ▼                                              ▼
┌────────────────────┐                      ┌──────────────────────────┐
│  voice-chef        │                      │  vertex-proxy            │
│  (Cloud Run)       │ ───────────────────▶ │  (Cloud Run, keyless)    │
└────────────────────┘     Vertex AI        └────────────┬─────────────┘
                                                          ▼
                                              Google Vertex AI (Gemini)
```

- **The app never holds an AI key.** All model calls go through the backend.
  The two Cloud Run services authenticate to Vertex AI with a short-lived
  identity token (no downloadable key anywhere), so usage bills to the Google
  Cloud project's credits.
- **Supabase is the source of truth** for the pantry, recipes, cook sessions,
  and chat history. The edge functions talk to the Vertex proxy with a shared
  secret; the app talks to the edge functions with the public Supabase anon key.

---

## Repository layout

```
PantryHub/                 The iOS app (SwiftUI). File-system-synchronized,
                           so any .swift added here is picked up automatically.
  AppStore.swift             App-wide state (pantry, feed, kitchen).
  Models.swift               Recipe / PantryItem and the scaling helpers.
  BackendService.swift       HTTP clients for every edge function.
  PantryIntakeService.swift  The four-door "add to pantry" client.
  AddPantryView.swift        The add-to-pantry hub (photo / barcode / voice).
  PhotoIntakeView.swift      Camera + gallery capture.
  BarcodeIntakeView.swift    Live barcode scanner (VisionKit).
  VoiceIntakeView.swift      Speak-your-groceries, live transcription.
  IntakeReviewView.swift     The shared review-and-confirm list.
  IngredientDetailView.swift The shared item editor (fullness, expiry, amount).
  ...                        Recipe feed, chefs, timers, Kitchen, etc.
  Config/
    Secrets.example.plist    Template — copy to Secrets.plist and fill in.

supabase/
  functions/               Deno edge functions (curate-recipes, text-chef,
                           recipe-author, pantry, pantry-intake, …).
  migrations/              SQL schema history.

cloud-run/
  vertex-proxy/            Keyless text proxy to Vertex AI.
  voice-chef/             WebSocket bridge to Vertex AI Live (voice).

HANDOFF.md                 Detailed running notes / current state of the build.
```

---

## Adding items to the pantry

The pantry intake is one flow with four front doors, all funnelling into the
same review screen and the same item editor:

| Door | Behind the scenes |
|------|-------------------|
| **Photo / Gallery** | One or more images go to `pantry-intake` → a Gemini vision model reads off each product (name, brand, category, size). |
| **Barcode** | The live scanner collects barcodes → looked up in [Open Food Facts](https://world.openfoodfacts.org) (free, no key). |
| **Voice** | Live transcription → `pantry-intake` cleans up spelling, splits the list, and fills in sensible defaults. |

Anything the AI or the lookup can't be sure about is flagged in the review list
so you can type it in. New items default to a full container, expiry dates are
estimated and flagged for you to confirm, and the editor shows a draggable jar
for liquids but a piece counter for things like eggs.

---

## Running it locally

### iOS app

1. Open `PantryHub.xcodeproj` in Xcode 16.
2. Copy the secrets template and fill in your own values:
   ```bash
   cp PantryHub/Config/Secrets.example.plist PantryHub/Config/Secrets.plist
   ```
   (The app ships with the public Supabase anon key already in
   `BackendService.swift`; `Secrets.plist` is for any extra local config.)
3. Build and run on a **real device** for the camera, barcode scanner, and
   microphone — those don't work in the simulator.

### Backend

The edge functions and Cloud Run services are already deployed. To change them
you'll need the Supabase and Google Cloud credentials (see `HANDOFF.md`).

- **Edge function:**
  `supabase functions deploy <name> --project-ref <ref> --no-verify-jwt`
- **Cloud Run:**
  `gcloud run deploy <service> --source <dir> --region us-central1`

---

## Security notes

- **Never commit secrets.** `Secrets.plist` and `.env.server` are git-ignored on
  purpose. Only their `.example` templates belong in the repo.
- The Supabase **anon** key and Clerk **publishable** key are public by design
  and safe to ship in the app. The service-role key and all AI/proxy secrets
  live only in server environments, never in the app or the repo.
- All edge functions run their own access checks and are deployed with
  `--no-verify-jwt`.

---

## Status

The front end is essentially complete and the backend is live. The most
detailed, up-to-date account of what's built, what's deployed, and what's next
lives in [`HANDOFF.md`](HANDOFF.md).
