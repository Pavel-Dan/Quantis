"""
Quantis - Cloud Function Gen2 (trigger_job)
Ecoute les notifications Pub/Sub de GCS et déclenche le Cloud Run Job.
"""
import os, json, base64
from google.auth import default
from google.auth.transport.requests import AuthorizedSession

PROJECT        = os.environ.get("PROJECT_ID")
REGION         = os.environ.get("REGION", "europe-west9")
JOB_NAME       = os.environ.get("JOB_NAME", "quantis-kpi-job")
ALLOWED_BUCKETS = set(
    filter(None, (os.environ.get("ALLOWED_BUCKETS") or "").split(","))
)


def _run_cloud_run_job() -> dict:
    creds, _ = default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    session  = AuthorizedSession(creds)
    url = (
        f"https://{REGION}-run.googleapis.com/apis/run.googleapis.com/v1"
        f"/namespaces/{PROJECT}/jobs/{JOB_NAME}:run"
    )
    resp = session.post(url, json={})
    if resp.status_code >= 300:
        raise RuntimeError(f"Cloud Run Jobs API error {resp.status_code}: {resp.text}")
    return resp.json()


def handler(event: dict, context) -> None:
    """Point d'entrée Cloud Function (Pub/Sub trigger)."""
    try:
        payload = json.loads(base64.b64decode(event["data"]).decode("utf-8"))
        bucket  = payload.get("bucket", "")
        name    = payload.get("name", "")

        # Filtres de sécurité
        if ALLOWED_BUCKETS and bucket not in ALLOWED_BUCKETS:
            print(f"[SKIP] Bucket non autorisé : {bucket}")
            return
        if not name.lower().endswith(".csv"):
            print(f"[SKIP] Fichier ignoré (non CSV) : {name}")
            return

        print(f"[TRIGGER] Nouveau fichier : gs://{bucket}/{name}")
        result = _run_cloud_run_job()
        print(f"[OK] Job lancé : {result.get('metadata', {}).get('name', 'unknown')}")

    except Exception as exc:
        # On ne relève pas l'exception pour éviter les retries infinis
        print(f"[ERROR] {exc}")
