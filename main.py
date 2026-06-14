"""
Quantis - ETL & KPI Engine
Lit les CSV depuis GCS, calcule les KPIs financiers, charge dans BigQuery.
"""
import os, io, sys, datetime as dt
import pandas as pd
from google.cloud import storage, bigquery

# ---------------------------------------------------------------------------
# Lecture GCS - robuste (teste plusieurs séparateurs)
# ---------------------------------------------------------------------------
def latest_csv_uri(bucket_name: str) -> str:
    client = storage.Client()
    blobs = [b for b in client.list_blobs(bucket_name) if b.name.lower().endswith(".csv")]
    if not blobs:
        raise RuntimeError(f"Aucun CSV dans gs://{bucket_name}")
    latest = max(blobs, key=lambda b: b.time_created)
    print(f"[INFO] Fichier retenu : gs://{bucket_name}/{latest.name}")
    return f"gs://{bucket_name}/{latest.name}"


def read_csv_gcs(uri: str) -> pd.DataFrame:
    """Télécharge et parse un CSV depuis GCS.
    Teste automatiquement les combinaisons (sep, decimal) courantes.
    """
    client = storage.Client()
    bucket, key = uri.replace("gs://", "").split("/", 1)
    raw = client.bucket(bucket).blob(key).download_as_bytes()

    for sep, dec in [(",", "."), (";", ","), (";", "."), ("\t", ".")]:
        try:
            df = pd.read_csv(io.BytesIO(raw), sep=sep, decimal=dec, engine="python")
            if df.shape[1] > 1:
                print(f"[INFO] CSV parsé OK sep='{sep}' decimal='{dec}' shape={df.shape}")
                return df
        except Exception:
            continue
    raise RuntimeError(f"Impossible de parser le CSV : {uri}")


# ---------------------------------------------------------------------------
# Mapping colonnes
# ---------------------------------------------------------------------------
COLUMNS_CDR = {
    "Company": "company", "Year": "year",
    "Revenues": "revenues",
    "Cost of Goods Sold (COGS)": "cogs",
    "GROSS PROFIT": "gross_profit",
    "Selling, General & Administrative (SG&A)": "sga",
    "Depreciation & Amortization": "depreciation",
    "OPERATING INCOME (EBIT)": "ebit",
    "Interest Expense": "interest_expense",
    "INCOME BEFORE TAX": "ibt",
    "Income Tax": "tax",
    "NET INCOME": "net_income",
}

COLUMNS_BS = {
    "Company": "company", "Year": "year",
    "Property, plant and equipment": "ppe",
    "Intangible assets": "intangibles",
    "Other non-current assets": "other_nca",
    "NON-CURRENT ASSETS": "non_current_assets",
    "Inventories": "inventories",
    "Trade receivables": "receivables",
    "Cash and cash equivalents": "cash",
    "Other current assets": "other_ca",
    "CURRENT ASSETS": "current_assets",
    "TOTAL ASSETS": "total_assets",
    "Share capital": "share_capital",
    "Retained earnings": "retained_earnings",
    "Net income": "net_income_bs",
    "EQUITY": "equity",
    "Long-term debt": "long_term_debt",
    "NON-CURRENT LIABILITIES": "non_current_liabilities",
    "Trade payables": "payables",
    "Other current liabilities": "other_cl",
    "CURRENT LIABILITIES": "current_liabilities",
    "TOTAL LIABILITIES": "total_liabilities",
    "TOTAL EQUITY AND LIABILITIES": "total_equity_and_liabilities",
}


# ---------------------------------------------------------------------------
# Calcul KPIs  (star schema : 1 ligne = 1 KPI pour 1 entreprise x 1 date)
# ---------------------------------------------------------------------------
def compute_kpis(cdr: pd.DataFrame, bs: pd.DataFrame) -> pd.DataFrame:
    cdr = cdr.rename(columns=COLUMNS_CDR)
    bs = bs.rename(columns=COLUMNS_BS)
    df = pd.merge(cdr, bs, on=["company", "year"], how="inner")

    rows = []
    for _, r in df.iterrows():
        company = str(r["company"])
        year = int(r["year"])
        report_date = dt.date(year, 12, 31)
        calc_ts = pd.Timestamp.utcnow()

        def safe(num, den=None):
            try:
                v = float(num) if den is None else float(num) / float(den)
                return v if pd.notna(v) else None
            except Exception:
                return None

        kpis = [
            # --- Rentabilité ---
            ("revenue",           "profitability", "EUR",  safe(r.get("revenues"))),
            ("gross_margin",      "profitability", "%",    safe(r.get("gross_profit"), r.get("revenues"))),
            ("operating_margin",  "profitability", "%",    safe(r.get("ebit"),         r.get("revenues"))),
            ("net_margin",        "profitability", "%",    safe(r.get("net_income"),   r.get("revenues"))),
            # --- Bilan ---
            ("total_assets",      "balance",       "EUR",  safe(r.get("total_assets"))),
            ("equity",            "balance",       "EUR",  safe(r.get("equity"))),
            ("long_term_debt",    "balance",       "EUR",  safe(r.get("long_term_debt"))),
            # --- Liquidité & solvabilité ---
            ("current_ratio",     "liquidity",     None,   safe(r.get("current_assets"), r.get("current_liabilities"))),
            ("debt_to_equity",    "solvency",      None,   safe(r.get("total_liabilities"), r.get("equity"))),
            ("return_on_equity",  "profitability", "%",    safe(r.get("net_income"),     r.get("equity"))),
        ]

        for name, category, unit, value in kpis:
            if value is not None:
                rows.append({
                    "company_name":  company,
                    "report_date":   report_date,
                    "kpi_name":      name,
                    "kpi_value":     value,
                    "kpi_category":  category,
                    "kpi_unit":      unit,
                    "calculation_ts": calc_ts,
                })

    result = pd.DataFrame(rows)
    print(f"[INFO] {len(result)} KPIs calculés pour {result['company_name'].nunique() if not result.empty else 0} entreprise(s)")
    return result


# ---------------------------------------------------------------------------
# BigQuery - schéma explicite
# ---------------------------------------------------------------------------
BQ_SCHEMA = [
    bigquery.SchemaField("company_name",   "STRING",    mode="REQUIRED"),
    bigquery.SchemaField("report_date",    "DATE",      mode="REQUIRED"),
    bigquery.SchemaField("kpi_name",       "STRING",    mode="REQUIRED"),
    bigquery.SchemaField("kpi_value",      "FLOAT64",   mode="REQUIRED"),
    bigquery.SchemaField("kpi_category",   "STRING",    mode="REQUIRED"),
    bigquery.SchemaField("kpi_unit",       "STRING",    mode="NULLABLE"),
    bigquery.SchemaField("calculation_ts", "TIMESTAMP", mode="REQUIRED"),
]


def upload_to_bq(df: pd.DataFrame, project: str, dataset: str, table: str) -> None:
    df["report_date"] = pd.to_datetime(df["report_date"]).dt.date
    df["calculation_ts"] = pd.to_datetime(df["calculation_ts"])
    df["kpi_value"] = pd.to_numeric(df["kpi_value"], errors="coerce")
    df = df.dropna(subset=["kpi_value"])

    client = bigquery.Client(project=project)
    table_id = f"{project}.{dataset}.{table}"
    job = client.load_table_from_dataframe(
        df, table_id,
        job_config=bigquery.LoadJobConfig(
            write_disposition="WRITE_APPEND",
            autodetect=False,
            schema=BQ_SCHEMA,
        )
    )
    job.result()
    print(f"[INFO] {len(df)} lignes chargées dans {table_id}")


# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
def main():
    project = os.environ["PROJECT_ID"]
    dataset = os.environ.get("BQ_DATASET", "quantis_analytics")
    table   = os.environ.get("BQ_TABLE",   "financial_kpis")
    bkt_bs  = os.environ["GCS_BUCKET_BILAN"]
    bkt_cdr = os.environ["GCS_BUCKET_CDR"]

    print(f"[INFO] Projet={project}  Dataset={dataset}  Table={table}")

    cdr = read_csv_gcs(latest_csv_uri(bkt_cdr))
    bs  = read_csv_gcs(latest_csv_uri(bkt_bs))

    out = compute_kpis(cdr, bs)
    if out.empty:
        print("[WARN] Aucun KPI calculé - arrêt.")
        sys.exit(0)

    upload_to_bq(out, project, dataset, table)


if __name__ == "__main__":
    main()
