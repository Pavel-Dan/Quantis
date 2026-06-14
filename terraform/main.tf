# =============================================================================
# Quantis - Infrastructure as Code (Terraform)
# Crée toute l'infrastructure GCP en une commande : terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# 1. STOCKAGE - Google Cloud Storage (Data Lake)
# =============================================================================

# Bucket bilans comptables
resource "google_storage_bucket" "balance_sheets" {
  name                        = "${var.project_id}-balance-sheets"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 365 }
  }

  labels = { environment = var.environment, project = "quantis" }
}

# Bucket comptes de résultat
resource "google_storage_bucket" "income_statements" {
  name                        = "${var.project_id}-income-statements"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 365 }
  }

  labels = { environment = var.environment, project = "quantis" }
}

# Bucket pour le code de la Cloud Function
resource "google_storage_bucket" "function_source" {
  name          = "${var.project_id}-function-source"
  location      = var.region
  force_destroy = true
  uniform_bucket_level_access = true
}

# =============================================================================
# 2. MESSAGING - Pub/Sub (déclencheur événementiel)
# =============================================================================

resource "google_pubsub_topic" "gcs_notifications" {
  name   = "quantis-csv-uploads"
  labels = { project = "quantis" }
}

# Notification GCS -> Pub/Sub sur le bucket bilans
resource "google_storage_notification" "balance_sheets_notif" {
  bucket         = google_storage_bucket.balance_sheets.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.gcs_notifications.id
  event_types    = ["OBJECT_FINALIZE"]
  depends_on     = [google_pubsub_topic_iam_member.gcs_publisher]
}

# Notification GCS -> Pub/Sub sur le bucket comptes de résultat
resource "google_storage_notification" "income_statements_notif" {
  bucket         = google_storage_bucket.income_statements.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.gcs_notifications.id
  event_types    = ["OBJECT_FINALIZE"]
  depends_on     = [google_pubsub_topic_iam_member.gcs_publisher]
}

# Autoriser GCS à publier dans le topic Pub/Sub
data "google_storage_project_service_account" "gcs_account" {}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.gcs_notifications.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# =============================================================================
# 3. DATA WAREHOUSE - BigQuery
# =============================================================================

resource "google_bigquery_dataset" "quantis" {
  dataset_id    = "quantis_analytics"
  friendly_name = "Quantis Analytics"
  description   = "KPIs financiers calculés par le pipeline Quantis"
  location      = "EU"
  labels        = { environment = var.environment, project = "quantis" }
}

resource "google_bigquery_table" "financial_kpis" {
  dataset_id          = google_bigquery_dataset.quantis.dataset_id
  table_id            = "financial_kpis"
  deletion_protection = false
  description         = "Table de faits - 1 ligne = 1 KPI pour 1 entreprise à 1 date"

  # Star schema : table de faits centrale
  schema = jsonencode([
    { name = "company_name",   type = "STRING",    mode = "REQUIRED", description = "Nom de l'entreprise" },
    { name = "report_date",    type = "DATE",      mode = "REQUIRED", description = "Date de clôture (31/12/YYYY)" },
    { name = "kpi_name",       type = "STRING",    mode = "REQUIRED", description = "Identifiant du KPI (ex: gross_margin)" },
    { name = "kpi_value",      type = "FLOAT64",   mode = "REQUIRED", description = "Valeur numérique du KPI" },
    { name = "kpi_category",   type = "STRING",    mode = "REQUIRED", description = "Catégorie : profitability | liquidity | solvency | balance" },
    { name = "kpi_unit",       type = "STRING",    mode = "NULLABLE", description = "Unité : EUR | % | null (ratio)" },
    { name = "calculation_ts", type = "TIMESTAMP", mode = "REQUIRED", description = "Horodatage UTC du calcul" }
  ])

  time_partitioning {
    type  = "MONTH"
    field = "report_date"
  }

  labels = { project = "quantis" }
}

# =============================================================================
# 4. COMPUTE - Cloud Run Job (ETL & calcul KPIs)
# =============================================================================

resource "google_cloud_run_v2_job" "kpi_job" {
  name     = "quantis-kpi-job"
  location = var.region

  template {
    template {
      service_account = google_service_account.cloud_run_sa.email
      max_retries     = 1
      timeout         = "120s"

      containers {
        image = "gcr.io/${var.project_id}/quantis-kpi:latest"

        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "BQ_DATASET"
          value = google_bigquery_dataset.quantis.dataset_id
        }
        env {
          name  = "BQ_TABLE"
          value = google_bigquery_table.financial_kpis.table_id
        }
        env {
          name  = "GCS_BUCKET_BILAN"
          value = google_storage_bucket.balance_sheets.name
        }
        env {
          name  = "GCS_BUCKET_CDR"
          value = google_storage_bucket.income_statements.name
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  labels = { project = "quantis", environment = var.environment }
}

# =============================================================================
# 5. COMPUTE - Cloud Function Gen2 (trigger)
# =============================================================================

# Archive du code source de la Cloud Function
data "archive_file" "trigger_job_source" {
  type        = "zip"
  output_path = "/tmp/trigger_job.zip"
  source_dir  = "${path.module}/../trigger_job"
}

resource "google_storage_bucket_object" "trigger_job_source" {
  name   = "trigger_job_${data.archive_file.trigger_job_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.trigger_job_source.output_path
}

resource "google_cloudfunctions2_function" "trigger_job" {
  name     = "quantis-trigger-job"
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "handler"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.trigger_job_source.name
      }
    }
  }

  service_config {
    service_account_email          = google_service_account.cloud_function_sa.email
    available_memory               = "256M"
    timeout_seconds                = 60
    max_instance_count             = 5
    environment_variables = {
      PROJECT_ID       = var.project_id
      REGION           = var.region
      JOB_NAME         = google_cloud_run_v2_job.kpi_job.name
      ALLOWED_BUCKETS  = "${google_storage_bucket.balance_sheets.name},${google_storage_bucket.income_statements.name}"
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.gcs_notifications.id
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
  }

  labels = { project = "quantis" }
}

# =============================================================================
# 6. IAM - Comptes de service & permissions
# =============================================================================

# Service account Cloud Run Job
resource "google_service_account" "cloud_run_sa" {
  account_id   = "quantis-cloud-run-sa"
  display_name = "Quantis Cloud Run Job SA"
  description  = "Lit GCS, écrit BigQuery"
}

# Service account Cloud Function
resource "google_service_account" "cloud_function_sa" {
  account_id   = "quantis-cf-sa"
  display_name = "Quantis Cloud Function SA"
  description  = "Déclenche le Cloud Run Job"
}

# Cloud Run Job : lire GCS
resource "google_project_iam_member" "run_gcs_reader" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Cloud Run Job : écrire BigQuery
resource "google_project_iam_member" "run_bq_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "run_bq_jobuser" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Cloud Function : déclencher Cloud Run Jobs
resource "google_project_iam_member" "cf_run_invoker" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.cloud_function_sa.email}"
}
