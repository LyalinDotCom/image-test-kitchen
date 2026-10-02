# Bug Report: `gemini-api image` Lacks Reference/Input Image Flags (`-i` / `--input`) Despite Advertising Image Editing

- **Component:** `gemini-api` CLI (`google-genai-cli/0.4.0`)
- **Subcommands Affected:** `gemini-api image` (primary), plus `gemini-api video` and `gemini-api generate`
- **Severity:** High (UX / Developer & Agent Ergonomics) — turns a core 1-line workflow into a multi-step schema discovery and raw JSON/base64 scripting exercise.

---

## 1. Summary of the Issue

Top-level `gemini-api --help` explicitly advertises that `image`, `video`, and `generate` support multimodal inputs and editing:

```text
Create:
  generate     Text & multimodal generation (gemini-3.8-flash)
  image        Generate or edit images (gemini-3.1-flash-image)
  ...
  video        Generate & edit video conversationally (gemini-omni-1.1-flash)
```

However, **`gemini-api image` only accepts a `<prompt>` string argument and has no `-i` / `--input` flag** to pass a reference or source image:

```text
$ gemini-api image --help
Generate an image from a text prompt via the Interactions API
(image response modality) and write it to a file; stdout
carries the file path. Use --out to choose the file (or a
directory), --raw-response to see the API response instead.

Arguments:
  <prompt>  Image prompt

Usage:
  gemini-api image [prompt] [flags]
```

By contrast, `gemini-api analyze` **already implements** `-i, --input stringArray` (supporting local file paths with automatic MIME detection and inline base64 encoding, as well as `files/<id>` handles resolved via `files.get`). Because `gemini-api image` omits `-i / --input`, passing a reference image with a prompt requires dropping all the way down to `--body` and hand-building the raw Interactions API JSON payload.

---

## 2. Why This Hurts Users & AI Agents (Token & Time Burn)

When a developer or coding agent tries to perform a standard image-to-image / reference-image task (`image + prompt -> image`), the current CLI forces a high-friction discovery loop:

1. **Contradictory help text:** `gemini-api --help` says `image: Generate or edit images`, but `gemini-api image --help` only documents text-to-image (`gemini-api image [prompt]`) with no mention of how to edit or pass an input image.
2. **Dumping a massive `--schema` to discover `input` structure:** Without a flag or example in `--help`, the user/agent must run `gemini-api image --schema` (which emits a huge single-line JSON Schema for the entire Interactions API) and manually inspect `$defs.ModelInteraction`, `$defs.InteractionsInput`, and `$defs.ImageContent`.
3. **Misleading schema annotation (`x-speakeasy-base64-input-mode: file`):** Inside `gemini-api image --schema`, `ImageContent.data` contains:
   ```json
   "data": {
     "description": "The image content.",
     "format": "byte",
     "type": "string",
     "x-speakeasy-base64-input-mode": "file"
   }
   ```
   This suggests `-b` / `--body` accepts a file path in `"data"` and encodes it automatically. In reality, passing a file path in `"data"` sends the literal filename string to the server and fails with:
   ```text
   Error (validation_error): The value is invalid for 'input[0].data'. Expected string, corrupt base64 (HTTP 400)
   ```
4. **Inconsistent `files/<id>` handling vs. `analyze`:**
   - `gemini-api files upload photo.jpg` prints `files/<id>` (e.g., `files/jtwjvlxh39cs`) by default and explicitly tells the user: *"Use that name with `gemini-api analyze`, `transcribe`, or advanced interaction requests."*
   - In `gemini-api analyze -i files/<id>`, the CLI automatically calls `files.get` to resolve the full URI (`https://generativelanguage.googleapis.com/v1beta/files/<id>`) and MIME type.
   - In `gemini-api image --body`, the user has to know to pass `--output-format json --jq '.uri'` to `files upload` and manually wire `uri` + `mime_type` into `input[0]`.
5. **Re-specifying boilerplate fields that `gemini-api image` normally sets:** Because `--body` *"replaces intent arguments"*, the user can no longer use the positional `<prompt>` or `-m / --model` flags alongside `--body`; they must manually include `"model"`, `"stream": false`, and `"response_format": {"type": "image"}` inside the JSON body.

---

## 3. Current Workarounds

Despite the missing `-i / --input` flag, **`gemini-api image` does support reference images today via `--body`**, while still using `gemini-api image`'s response handler to extract the generated image and write it to `--out`.

### Workaround A: Inline Base64 via `--body @-` (Single Command)

Base64-encode the local reference image into `input[0].data` and pass the prompt text in `input[1].text`:

```bash
jq -n \
  --rawfile prompt prompt-image01.md \
  --arg b64 "$(base64 -i "Screenshot 2026-10-01 at 2.19.42 AM.jpeg")" \
  '{
    model: "gemini-3-pro-image",
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
  }' | gemini-api image --body @- --out images/gemini-3-pro-image.jpg
```

*(Swap `model` to `"gemini-3.1-flash-image"` for the default Flash Image model, and set `aspect_ratio` to match your reference image so models like `gemini-3-pro-image` never drift to landscape.)*

### Workaround B: Upload Once via `gemini-api files upload`, Pass `uri`

Useful when iterating on prompts against the same reference image so you don't re-encode and re-upload base64 on every call:

```bash
# 1. Upload the reference image and grab its full HTTPS URI
FILE_URI=$(gemini-api files upload "Screenshot 2026-10-01 at 2.19.42 AM.jpeg" --output-format json --jq '.uri')

# 2. Reference the uploaded file URI in input[0].uri
jq -n \
  --rawfile prompt prompt-image01.md \
  --arg uri "$FILE_URI" \
  '{
    model: "gemini-3.1-flash-image",
    stream: false,
    response_format: { type: "image" },
    generation_config: {
      image_config: {
        aspect_ratio: "9:16"
      }
    },
    input: [
      { type: "image", mime_type: "image/jpeg", uri: $uri },
      { type: "text", text: $prompt }
    ]
  }' | gemini-api image --body @- --out images/gemini-3.1-flash-image.jpg
```

---

## 4. Proposed CLI Improvements (Recommendations for the Team)

### 1. Add `-i, --input` (Repeatable) to `gemini-api image` (and `video` / `generate`)
Reuse the exact media-loading helper that `gemini-api analyze` already uses:
- **Local files (`-i ref.jpg`):** Auto-detect MIME type from extension/magic bytes and inline as base64 in `input[]` (under the 20 MB threshold).
- **Files API IDs (`-i files/abc123`):** Automatically resolve `uri` and `mime_type` via `files.get`, matching `gemini-api analyze`.
- **Multiple reference images (`-i img1.jpg -i img2.jpg`):** Append each image block to `input[]` before the text prompt block (`{"type": "text", "text": "<prompt>"}`), enabling style transfer, multi-reference composition, and image editing in one flag.

With this change, the entire `jq` + `base64` workaround collapses into:
```bash
gemini-api image -i "Screenshot 2026-10-01 at 2.19.42 AM.jpeg" "Redraw as an architectural illustration..." --out rendered.jpg
```

### 2. Support Reading Prompts from Files (`@path` or `--prompt-file`)
Detailed image generation and architectural/style redraw prompts are frequently stored in `.md` or `.txt` files (like `prompt-image01.md`).
- Support `--prompt-file <path>` (or `@path` / `@-` on the `<prompt>` argument, consistent with `--body @path`).
- Example target UX:
  ```bash
  gemini-api image \
    -i "Screenshot 2026-10-01 at 2.19.42 AM.jpeg" \
    --prompt-file prompt-image01.md \
    --model gemini-3-pro-image \
    --out rendered.jpg
  ```

### 3. Update `gemini-api image --help` Description and "Just works" Examples
Currently `gemini-api image --help` only mentions generating an image from a text prompt. Update both the description and the `Just works:` section to show image editing / reference image usage:

```text
Generate or edit an image from a text prompt and optional input images
via the Interactions API (image response modality) and write it to a file.

Just works:
  gemini-api image "a lighthouse at sunset"
  gemini-api image "product shot, white bg" --out shots/hero.png
  gemini-api image -i sketch.jpeg "Redraw as a polished architectural illustration" --out render.jpg
  gemini-api image -i files/abc123 "Change the background to sunset" --model gemini-3-pro-image
```

### 4. Fix or Clarify `x-speakeasy-base64-input-mode: file` in `--schema`
Either:
- Have `--body` / `-b` honor `"x-speakeasy-base64-input-mode": "file"` when a valid local file path or `@path` is supplied in `input[].data`, **or**
- Strip `"x-speakeasy-base64-input-mode": "file"` from the printed `--schema` and update the description of `ImageContent.data` to explicitly state: *"Base64-encoded image bytes (use `uri` for Files API references)."*

### 5. Allow `--model` and `--out` to Layer Cleanly Over Partial `-b / --body-param`
If a user uses `-b` for advanced fields (e.g., `generation_config` or `safety_settings`), allow intent flags (`<prompt>`, `-i`, `-m`, `--out`) to merge with `-b` rather than forcing the user to reconstruct the entire request envelope from scratch.
