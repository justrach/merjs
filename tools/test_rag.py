#!/usr/bin/env python3
"""Quick test: check namespaces, embed a question, search EmergentDB, print chunks."""

import json
import os
import urllib.request
import urllib.error

OPENAI_KEY   = os.environ.get("OPENAI_API_KEY", "")
EMERGENT_KEY = os.environ.get("EMERGENT_API_KEY", "")
NAMESPACE    = "budget2026"
QUESTION     = "What are the GST changes in Budget 2026?"

EMERGENT_HEADERS = {
    "Authorization": f"Bearer {EMERGENT_KEY}",
    "Content-Type": "application/json",
    "User-Agent": "EmergentDB-Ingest/1.0",
}

def emergent_get(path):
    req = urllib.request.Request(
        f"https://api.emergentdb.com{path}",
        headers=EMERGENT_HEADERS,
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()}

def emergent_post(path, body):
    req = urllib.request.Request(
        f"https://api.emergentdb.com{path}",
        data=json.dumps(body).encode(),
        headers=EMERGENT_HEADERS,
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()}

# 0. Check namespaces
print("0. Checking EmergentDB namespaces...")
ns = emergent_get("/vectors/namespaces")
print(f"   Raw response: {ns}\n")

# 1. Embed
print(f"1. Embedding: '{QUESTION}'")
req = urllib.request.Request(
    "https://api.openai.com/v1/embeddings",
    data=json.dumps({"model": "text-embedding-3-small", "input": QUESTION}).encode(),
    headers={"Authorization": f"Bearer {OPENAI_KEY}", "Content-Type": "application/json"},
)
with urllib.request.urlopen(req) as r:
    data = json.loads(r.read())
embedding = data["data"][0]["embedding"]
print(f"   dim={len(embedding)}\n")

# 2. Search — try both with and without namespace
for ns_arg in [NAMESPACE, "default", None]:
    body = {"vector": embedding, "k": 5, "include_metadata": True}
    if ns_arg:
        body["namespace"] = ns_arg
    print(f"2. Searching namespace={ns_arg!r}...")
    result = emergent_post("/vectors/search", body)
    print(f"   Raw: {json.dumps(result)[:500]}\n")
