// vertex-proxy — keyless Cloud Run proxy to Vertex AI generateContent.
//
// Runs AS the attached service account, so it gets short-lived access tokens
// from the GCE metadata server — NO downloadable key anywhere (org policy
// forbids those). Supabase edge functions call this with a shared-secret
// header; this service authenticates to Vertex on their behalf, so all usage
// bills to the GCP project and draws from the free credits.

const http = require("http");

const PROJECT = process.env.GCP_PROJECT;
const LOCATION = process.env.GCP_LOCATION || "global";
const SECRET = process.env.PROXY_SECRET || "";
const DEFAULT_MODEL = "gemini-3.1-flash-lite";

const TOKEN_URL =
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

// Access tokens last ~1h; cache per warm instance and refresh 60s early.
let cachedToken = null;
let cachedExp = 0;
async function getToken() {
  const now = Date.now();
  if (cachedToken && now < cachedExp - 60_000) return cachedToken;
  const r = await fetch(TOKEN_URL, { headers: { "Metadata-Flavor": "Google" } });
  if (!r.ok) throw new Error(`metadata token ${r.status}: ${await r.text()}`);
  const j = await r.json();
  cachedToken = j.access_token;
  cachedExp = now + (j.expires_in || 3600) * 1000;
  return cachedToken;
}

function vertexHost() {
  return LOCATION === "global"
    ? "aiplatform.googleapis.com"
    : `${LOCATION}-aiplatform.googleapis.com`;
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      return res.end("ok");
    }
    if (req.method !== "POST") {
      res.writeHead(405);
      return res.end("method not allowed");
    }
    if (SECRET && req.headers["x-proxy-secret"] !== SECRET) {
      res.writeHead(401, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: "unauthorized" }));
    }

    let raw = "";
    for await (const chunk of req) raw += chunk;
    const payload = raw ? JSON.parse(raw) : {};
    // Caller sends the exact Vertex body (contents/systemInstruction/
    // generationConfig/tools) plus an optional `model`. We forward the rest
    // untouched so callers need no response-shape changes.
    const { model, ...vertexBody } = payload;
    const m = model || DEFAULT_MODEL;

    const token = await getToken();
    const url = `https://${vertexHost()}/v1/projects/${PROJECT}/locations/${LOCATION}/publishers/google/models/${m}:generateContent`;
    const vres = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(vertexBody),
    });
    const text = await vres.text();
    res.writeHead(vres.status, { "Content-Type": "application/json" });
    res.end(text);
  } catch (e) {
    res.writeHead(500, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: String(e && e.message ? e.message : e) }));
  }
});

server.listen(process.env.PORT || 8080, () => {
  console.log(`vertex-proxy up on ${process.env.PORT || 8080} project=${PROJECT} location=${LOCATION}`);
});
