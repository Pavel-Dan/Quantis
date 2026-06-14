output "bucket_balance_sheets" {
  description = "Bucket GCS pour les bilans"
  value       = google_storage_bucket.balance_sheets.name
}

output "bucket_income_statements" {
  description = "Bucket GCS pour les comptes de résultat"
  value       = google_storage_bucket.income_statements.name
}

output "bigquery_table" {
  description = "Table BigQuery cible"
  value       = "${google_bigquery_dataset.quantis.dataset_id}.${google_bigquery_table.financial_kpis.table_id}"
}

output "cloud_function_name" {
  description = "Nom de la Cloud Function trigger"
  value       = google_cloudfunctions2_function.trigger_job.name
}

output "cloud_run_job_name" {
  description = "Nom du Cloud Run Job ETL"
  value       = google_cloud_run_v2_job.kpi_job.name
}
