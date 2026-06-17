// RETIRED — voice-chef moved off Supabase edge functions.
//
// The live voice cooking assistant now runs on Cloud Run (Node + ws) talking to
// Vertex AI Live (model gemini-live-2.5-flash, location global), keyless via the
// GCE metadata server and billed to the GCP credits. Long voice calls no longer
// hit edge-function execution limits.
//
//   Source:   cloud-run/voice-chef/
//   Endpoint: wss://voice-chef-289946863771.us-central1.run.app/?cook_session_id=<uuid>
//   iOS:      BackendService.voiceChefWS(cookSessionID:)
//
// The old AI Studio (AIzaSy…) key that used to live here has been removed; the
// Supabase deployment of this function has been deleted. This stub remains only
// so the previous Deno implementation can be recovered from git history.

Deno.serve(() =>
  new Response("voice-chef has moved to Cloud Run. See cloud-run/voice-chef/.", {
    status: 410,
    headers: { "Content-Type": "text/plain" },
  })
);
