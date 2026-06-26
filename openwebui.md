# Open WebUI — configuration notes

This deployment runs **Open WebUI v0.9.6** (`ghcr.io/open-webui/open-webui:v0.9.6`) on Azure Container Apps, with **Docling** as the document extraction backend.

## OpenAI API

In v0.9.6, the **OpenAI API** connection type uses the experimental **Responses API**. When adding an OpenAI connection in **Admin Panel → Settings → Connections**, expect behaviour and endpoint details to differ from the standard Chat Completions API. Test model calls after any upgrade.

## Docling integration

Open WebUI talks to the internal Docling container app via `DOCLING_SERVER_URL` (set automatically by `./Apps/create_apps.sh`).

### Open WebUI settings (Admin Panel)

After deployment, configure document extraction in **Admin Panel → Settings → Documents**:

1. Set **Default content extraction engine** to **Docling**.
2. Set the extraction engine URL to the internal Docling URL (already wired by the deployment script).
3. Paste the following **Docling parameters** (`DOCLING_PARAMS`):

```json
{
  "do_ocr": true,
  "pdf_backend": "dlparse_v4",
  "table_mode": "fast",
  "ocr_engine": "tesseract",
  "ocr_lang": [
    "deu",
    "eng"
  ]
}
```

These parameters control OCR, PDF parsing, and table extraction inside Docling. They are configured in the Open WebUI admin UI (or via a `DOCLING_PARAMS` environment variable on the Open WebUI container), not in `config.yaml`.

For full integration steps, environment variable reference, and troubleshooting, see the official guide: [Docling Document Extraction — Open WebUI](https://docs.openwebui.com/features/chat-conversations/rag/document-extraction/docling/).

### Docling container — recommended environment variables

The deployment script currently sets only `UVICORN_WORKERS` and `DOCLING_SERVE_MAX_SYNC_WAIT` (the latter can be tuned via `resources.docling` in `config.yaml`). For production limits and performance tuning, add the following environment variables on the **Docling** container app:

| Variable | Value | Purpose |
|----------|-------|---------|
| `DOCLING_SERVE_MAX_SYNC_WAIT` | `240` | Sync request timeout (240 s ceiling) |
| `DOCLING_SERVE_MAX_PROCESSING_TIME` | `240` | Kill conversion after 240 s |
| `DOCLING_SERVE_MAX_FILE_SIZE` | `20971520` | Reject files larger than 20 MB |
| `DOCLING_SERVE_MAX_PAGES` | `100` | Reject documents with more than 100 pages |
| `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` | `2` | Local engine worker count |
| `UVICORN_WORKERS` | `1` | **Must stay at 1** — higher values cause "Task Not Found" errors |
| `OMP_NUM_THREADS` | `4` | CPU thread count |
| `MKL_NUM_THREADS` | `4` | Intel MKL thread count |
| `DOCLING_SERVE_ENABLE_UI` | `true` | Enable Docling web UI at `/ui` (useful for testing) |

These are **not** part of `config.yaml`. To apply them:

- **Azure Portal** — Container Apps → Docling app → **Containers** → **Environment variables**, or
- **Deployment script** — extend `ensure_docling_container_app` in [`Apps/_lib_apps.sh`](Apps/_lib_apps.sh) (the `--env-vars` / `--set-env-vars` flags used during `containerapp create` / `update`).

Re-run `./Apps/create_apps.sh` after changing the script, or update the container app directly in the portal for a one-off change.

> **Important:** Keep `UVICORN_WORKERS=1` unless you configure shared state (e.g. Redis). See the [Open WebUI Docling docs](https://docs.openwebui.com/features/chat-conversations/rag/document-extraction/docling/) for details.

## Azure Document Intelligence (alternative)

Open WebUI can also use **Azure Document Intelligence** (formerly Form Recognizer) as a document extraction engine instead of Docling. This is configured in **Admin Panel → Settings → Documents** by selecting the Azure/content-extraction option and supplying endpoint and API key credentials.

Using Document Intelligence requires a separate **Azure Document Intelligence** resource deployment (not included in the default `./Apps/create_apps.sh` stack). Provision the service in Azure, then enter the endpoint and key in Open WebUI. No Docling container is needed for that extraction path, but the Docling app can remain running if you want both options available.
