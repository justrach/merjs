#!/usr/bin/env python3
"""
Ingest a PDF into EmergentDB using OpenAI text-embedding-3-small.

Usage:
    pip install pypdf
    python tools/ingest_pdf.py /path/to/file.pdf

Env vars (or prompted):
    OPENAI_API_KEY
    EMERGENT_API_KEY
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

try:
    from pypdf import PdfReader
except ImportError:
    print("Error: pypdf not installed. Run: pip install pypdf")
    sys.exit(1)

OPENAI_EMBED_URL  = "https://api.openai.com/v1/embeddings"
EMERGENT_BATCH_URL = "https://api.emergentdb.com/vectors/batch_insert"
EMBED_MODEL = "text-embedding-3-small"


# ── PDF → text ────────────────────────────────────────────────────────────────

def extract_text(pdf_path: str) -> str:
    reader = PdfReader(pdf_path)
    pages = []
    for page in reader.pages:
        text = page.extract_text()
        if text:
            pages.append(text.strip())
    return "\n\n".join(pages)


# ── Chunking ──────────────────────────────────────────────────────────────────

def chunk_text(text: str, chunk_size: int = 500, overlap: int = 50) -> list[str]:
    words = text.split()
    chunks: list[str] = []
    start = 0
    while start < len(words):
        end = min(start + chunk_size, len(words))
        chunks.append(" ".join(words[start:end]))
        if end == len(words):
            break
        start += chunk_size - overlap
    return chunks


# ── Embeddings ────────────────────────────────────────────────────────────────

def embed_texts(texts: list[str], api_key: str, batch_size: int = 100) -> list[list[float]]:
    all_embeddings: list[list[float]] = []
    total_batches = (len(texts) + batch_size - 1) // batch_size

    for i in range(0, len(texts), batch_size):
        batch = texts[i : i + batch_size]
        payload = json.dumps({"model": EMBED_MODEL, "input": batch}).encode()
        req = urllib.request.Request(
            OPENAI_EMBED_URL,
            data=payload,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            print(f"OpenAI error {e.code}: {body}", file=sys.stderr)
            sys.exit(1)

        # sort by index to preserve order
        items = sorted(data["data"], key=lambda x: x["index"])
        all_embeddings.extend(d["embedding"] for d in items)

        batch_num = i // batch_size + 1
        print(f"  Embedded batch {batch_num}/{total_batches} ({len(batch)} chunks)")
        if batch_num < total_batches:
            time.sleep(0.1)  # gentle rate-limit headroom

    return all_embeddings


# ── Upload ────────────────────────────────────────────────────────────────────

def upload_to_emergent(
    chunks: list[str],
    embeddings: list[list[float]],
    api_key: str,
    namespace: str = "budget2026",
    batch_size: int = 100,
) -> None:
    total_batches = (len(chunks) + batch_size - 1) // batch_size

    for i in range(0, len(chunks), batch_size):
        batch_chunks = chunks[i : i + batch_size]
        batch_embeddings = embeddings[i : i + batch_size]
        vectors = [
            {
                "id": i + j + 1,  # positive integer, 1-indexed
                "vector": emb,
                "metadata": {
                    "text": chunk,
                    "chunk_index": i + j,
                },
            }
            for j, (chunk, emb) in enumerate(zip(batch_chunks, batch_embeddings))
        ]
        payload = json.dumps({"vectors": vectors, "namespace": namespace}).encode()
        req = urllib.request.Request(
            EMERGENT_BATCH_URL,
            data=payload,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "User-Agent": "EmergentDB-Ingest/1.0",
            },
        )
        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            print(f"EmergentDB error {e.code}: {body}", file=sys.stderr)
            sys.exit(1)

        batch_num = i // batch_size + 1
        print(f"  Uploaded batch {batch_num}/{total_batches}: {data.get('count', '?')} vectors (upserted={data.get('upserted_count', '?')})")

# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest PDF into EmergentDB via OpenAI embeddings")
    parser.add_argument("pdf", help="Path to PDF file")
    parser.add_argument("--chunk-size", type=int, default=500, help="Words per chunk (default: 500)")
    parser.add_argument("--overlap",    type=int, default=50,  help="Overlap words between chunks (default: 50)")
    parser.add_argument("--namespace",  default="budget2026",  help="EmergentDB namespace (default: budget2026)")
    args = parser.parse_args()

    openai_key   = os.environ.get("OPENAI_API_KEY")  or input("OpenAI API key: ").strip()
    emergent_key = os.environ.get("EMERGENT_API_KEY") or input("EmergentDB API key: ").strip()

    print(f"\n📄 Reading: {args.pdf}")
    text = extract_text(args.pdf)
    print(f"   Extracted {len(text):,} characters across all pages")

    print(f"\n✂️  Chunking (size={args.chunk_size}, overlap={args.overlap})...")
    chunks = chunk_text(text, args.chunk_size, args.overlap)
    print(f"   Created {len(chunks)} chunks")

    print(f"\n🔢 Generating embeddings ({EMBED_MODEL})...")
    embeddings = embed_texts(chunks, openai_key)
    print(f"   Generated {len(embeddings)} embeddings (dim={len(embeddings[0])})")

    print(f"\n⬆️  Uploading to EmergentDB namespace='{args.namespace}'...")
    upload_to_emergent(chunks, embeddings, emergent_key, args.namespace)

    print(f"\n✅ Done — {len(chunks)} chunks in namespace '{args.namespace}'")


if __name__ == "__main__":
    main()
