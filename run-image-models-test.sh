#!/usr/bin/env bash
set -euo pipefail

REF_IMAGE="${1:-Screenshot 2026-10-01 at 2.19.42 AM.jpeg}"
PROMPT_FILE="${2:-prompt-image01.md}"
OUT_DIR="${3:-images}"

# All image models in `gemini-api models` + live `gemini-api models list`
MODELS=(
  "gemini-2.5-flash-image"
  "gemini-3-pro-image"
  "nano-banana-pro-preview"
  "gemini-3.1-flash-image"
  "gemini-3.1-flash-lite-image"
)

if [[ ! -f "$REF_IMAGE" ]]; then
  echo "Error: Reference image not found: $REF_IMAGE" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "Encoding reference image: $REF_IMAGE"
B64_FILE="$(mktemp)"
trap 'rm -f "$B64_FILE"' EXIT
base64 -i "$REF_IMAGE" | tr -d '\n\r' > "$B64_FILE"

for MODEL in "${MODELS[@]}"; do
  OUT_FILE="${OUT_DIR}/${MODEL}.jpg"
  echo "============================================================"
  echo "Testing model: $MODEL -> $OUT_FILE"
  echo "============================================================"

  if jq -n \
    --arg model "$MODEL" \
    --rawfile prompt "$PROMPT_FILE" \
    --rawfile b64 "$B64_FILE" \
    '{
      model: $model,
      stream: false,
      response_format: { type: "image" },
      generation_config: {
        image_config: {
          aspect_ratio: "9:16"
        }
      },
      input: [
        { type: "image", mime_type: "image/jpeg", data: $b64 },
        { type: "text", text: $prompt }
      ]
    }' | gemini-api image --body @- --out "$OUT_FILE"; then
    echo "[OK] Generated output for $MODEL"
  else
    echo "[FAIL] Model $MODEL failed" >&2
  fi
  echo ""
done
