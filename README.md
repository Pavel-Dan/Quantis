# Quantis

> *"Understand the past, diagnose the present, to predict the future."*

Quantis est une plateforme SaaS qui transforme des documents comptables bruts (bilans, comptes de résultat) en **indicateurs financiers automatisés et visualisables**.

---

## Table des matières

1. [Contexte et problème](#1-contexte-et-problème)
2. [Solution et architecture](#2-solution-et-architecture)
3. [Modèle de données](#3-modèle-de-données)
4. [Stack technique et justification des choix](#4-stack-technique-et-justification-des-choix)
5. [Structure du repo](#5-structure-du-repo)
6. [Déploiement - Infrastructure as Code](#6-déploiement---infrastructure-as-code)
7. [Monitoring et observabilité](#7-monitoring-et-observabilité)
8. [KPIs calculés](#8-kpis-calculés)

---

## 1. Contexte et problème

Chaque année, des milliers de dirigeants de PME naviguent à l'aveugle : leurs données financières restent une source de stress, réservée à des experts coûteux. Quantis change les règles en mettant la **puissance d'un DAF** entre les mains de chaque entrepreneur.

**Besoins identifiés :**
- Collecter des documents comptables multi-formats (CSV, Excel)
- Calculer automatiquement des KPIs financiers fiables
- Visualiser les indicateurs via des dashboards interactifs
- Garantir l'isolation des données entre clients (conformité RGPD)

---

## 2. Solution et architecture

### Architecture globale

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         QUANTIS PIPELINE                                │
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────────┐                       │
│  │  Google  │    │   Apps   │    │     GCS      │  Data Lake            │
│  │  Forms   │───▶│  Script  │───▶│  (2 buckets) │                       │
│  │  (UI)    │    │          │    │              │                       │
│  └──────────┘    └──────────┘    └──────┬───────┘                       │
│                                         │ OBJECT_FINALIZE               │
│                                         ▼                               │
│                                  ┌──────────────┐                       │
│                                  │   Pub/Sub    │  Event Bus            │
│                                  │    Topic     │                       │
│                                  └──────┬───────┘                       │
│                                         │                               │
│                                         ▼                               │
│                                  ┌──────────────┐                       │
│                                  │    Cloud     │  Trigger              │
│                                  │  Function    │                       │
│                                  │  Gen2        │                       │
│                                  └──────┬───────┘                       │
│                                         │                               │
│                                         ▼                               │
│                                  ┌──────────────┐    ┌──────────────┐  │
│                                  │  Cloud Run   │───▶│   BigQuery   │  │
│                                  │    Job       │    │ (Warehouse)  │  │
│                                  │  (ETL+KPIs)  │    │              │  │
│                                  └──────────────┘    └──────┬───────┘  │
│                                                             │           │
│  ┌──────────┐                                               │           │
│  │  Grafana │◀──────────────────────────────────────────────┘           │
│  │(Dashboard│                                                           │
│  └──────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────┘

Monitoring local : Prometheus + Grafana (docker-compose)
```

### Flux de données (étape par étape)

| Étape | Composant | Rôle |
|-------|-----------|------|
| 1 | Google Forms + Apps Script | L'utilisateur dépose ses CSV. Apps Script les renomme (unicité) et les envoie vers GCS |
| 2 | Cloud Storage (2 buckets) | Data lake - stockage brut des bilans et comptes de résultat |
| 3 | Pub/Sub | Événement `OBJECT_FINALIZE` publié dès qu'un CSV arrive dans un bucket |
| 4 | Cloud Function Gen2 | Ecoute Pub/Sub, filtre les buckets autorisés, déclenche le Cloud Run Job |
| 5 | Cloud Run Job | ETL complet : lit les CSV, calcule 10 KPIs, charge dans BigQuery |
| 6 | BigQuery | Data warehouse - table de faits partitionnée par mois |
| 7 | Grafana | Dashboards financiers en temps réel |

---

## 3. Modèle de données

### ERD (Entity-Relationship Diagram)

```
┌─────────────────────┐         ┌───────────────────────────┐
│      companies      │         │       financial_kpis       │
├─────────────────────┤         ├───────────────────────────┤
│ company_name (PK)   │◀────────│ company_name (FK)          │
│ sector              │  1   N  │ report_date    (FK)        │
│ country             │         │ kpi_name       (FK)        │
│ created_at          │         │ kpi_value                  │
└─────────────────────┘         │ kpi_category               │
                                │ kpi_unit                   │
┌─────────────────────┐         │ calculation_ts             │
│    kpi_definitions  │         └───────────────────────────┘
├─────────────────────┤                    │
│ kpi_name     (PK)   │◀───────────────────┘
│ category            │         N
│ formula             │
│ unit                │
└─────────────────────┘
```

### Star Schema (implémenté dans BigQuery)

La table `financial_kpis` suit un **schéma en étoile** (format long/tall) :
- **Table de faits centrale** : `financial_kpis` - une ligne = un KPI pour une entreprise à une date
- **Dimensions implicites** : `company_name`, `report_date`, `kpi_name`, `kpi_category`

Ce format permet des requêtes analytiques efficaces (`GROUP BY kpi_name`, filtres par catégorie, comparaisons temporelles) sans jointures complexes.

```
                    ┌──────────────────────────┐
                    │    financial_kpis         │
                    │    (table de faits)       │
                    ├──────────────────────────┤
         ┌──────────│ company_name  STRING      │──────────┐
         │          │ report_date   DATE         │          │
         │          │ kpi_name      STRING       │          │
         │          │ kpi_value     FLOAT64      │          │
         │          │ kpi_category  STRING       │          │
         │          │ kpi_unit      STRING       │          │
         │          │ calculation_ts TIMESTAMP   │          │
         │          └──────────────────────────┘          │
         │                                                  │
         ▼                                                  ▼
┌─────────────────┐                             ┌──────────────────┐
│  dim_company    │                             │  dim_kpi         │
│  (dimension)    │                             │  (dimension)     │
├─────────────────┤                             ├──────────────────┤
│ company_name PK │                             │ kpi_name      PK │
│ sector          │                             │ category         │
│ country         │                             │ formula          │
│ created_at      │                             │ unit             │
└─────────────────┘                             └──────────────────┘
```

### Schéma de la table BigQuery

```sql
CREATE TABLE quantis_analytics.financial_kpis (
  company_name    STRING    NOT NULL,  -- Nom de l'entreprise cliente
  report_date     DATE      NOT NULL,  -- Date de clôture fiscale (31/12/YYYY)
  kpi_name        STRING    NOT NULL,  -- Identifiant du KPI
  kpi_value       FLOAT64   NOT NULL,  -- Valeur numérique
  kpi_category    STRING    NOT NULL,  -- profitability | liquidity | solvency | balance
  kpi_unit        STRING,              -- EUR | % | NULL (pour les ratios)
  calculation_ts  TIMESTAMP NOT NULL   -- Horodatage UTC du calcul ETL
)
PARTITION BY MONTH(report_date);
```

---

## 4. Stack technique et justification des choix

| Composant | Technologie | Justification |
|-----------|-------------|---------------|
| **Cloud Provider** | Google Cloud Platform | Écosystème data mature (BigQuery, GCS natifs), IAM granulaire, tarification à l'usage adaptée à une startup |
| **Ingestion** | Google Forms + Apps Script | Zéro friction pour l'utilisateur final, pas d'UI à développer en phase MVP |
| **Data Lake** | Cloud Storage (GCS) | Stockage objet managé, durabilité 99.999999999%, coût très faible ($0.02/Go/mois) |
| **Event Bus** | Pub/Sub | Découplage total entre ingestion et traitement, garanti "at-least-once", serverless |
| **Trigger** | Cloud Function Gen2 | Exécution événementielle sans serveur, coût nul hors usage |
| **ETL & Calcul** | Cloud Run Job + Python | Conteneur éphémère, isolation totale, scaling à 0, coût uniquement à l'exécution |
| **Data Warehouse** | BigQuery | SQL analytique managé, partitionnement natif, connecteur Grafana natif |
| **Visualisation** | Grafana | Open-source, connecteur BigQuery officiel, dashboards en code (JSON) |
| **Monitoring** | Prometheus + Grafana | Stack standard industrie, monitoring as code, alertes configurables |
| **IaC** | Terraform | Reproductibilité totale de l'infra, gestion des dépendances entre ressources, state management |
| **Conteneurisation** | Docker | Portabilité, reproductibilité des environnements d'exécution |
| **Langage** | Python 3.11 | Ecosystème data (Pandas, PyArrow), bibliothèques GCP officielles |

---

## 5. Structure du repo

```
quantis/
├── main.py                    # ETL principal - Cloud Run Job
├── requirements.txt           # Dépendances Python
├── Dockerfile                 # Image du Cloud Run Job
│
├── trigger_job/               # Cloud Function Gen2
│   ├── main.py                # Handler Pub/Sub -> déclenche Cloud Run Job
│   └── requirements.txt
│
├── scripts/                   # Utilitaires
│   └── generate_data.py       # Génère des CSV de test réalistes
│
├── terraform/                 # Infrastructure as Code
│   ├── main.tf                # Ressources GCP (GCS, Pub/Sub, BQ, Cloud Run, CF)
│   ├── variables.tf           # Variables paramétrables
│   ├── outputs.tf             # Sorties après apply
│   └── terraform.tfvars.example  # Template de configuration
│
├── docker/                    # Stack monitoring locale
│   ├── docker-compose.yml     # Lance Prometheus + Grafana
│   ├── prometheus.yml         # Configuration Prometheus
│   └── grafana/
│       ├── provisioning/      # Auto-config datasources & dashboards
│       └── dashboards/        # Dashboard JSON Quantis
│
└── README.md
```

---

## 6. Déploiement - Infrastructure as Code

### Prérequis

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installé et authentifié
- [Docker](https://www.docker.com/products/docker-desktop/) installé
- Un projet GCP actif avec facturation activée

### Étape 1 - Authentification GCP

```bash
gcloud auth application-default login
gcloud config set project VOTRE-PROJECT-ID
```

### Étape 2 - Activer les APIs GCP nécessaires

```bash
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  pubsub.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com
```

### Étape 3 - Configurer Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editez terraform.tfvars et renseignez votre project_id
```

### Étape 4 - Déployer l'infrastructure

```bash
terraform init
terraform plan    # Prévisualise les ressources à créer
terraform apply   # Crée les ressources (confirmation requise)
```

### Étape 5 - Builder et pousser l'image Docker

```bash
# Depuis la racine du repo
gcloud builds submit --tag gcr.io/VOTRE-PROJECT-ID/quantis-kpi:latest .
```

### Étape 6 - Tester le pipeline

```bash
# Générer des données de test
python scripts/generate_data.py

# Uploader dans GCS pour déclencher le pipeline
gsutil cp income_statement.csv gs://VOTRE-PROJECT-ID-income-statements/
gsutil cp balance_sheet.csv gs://VOTRE-PROJECT-ID-balance-sheets/
```

### Destruction de l'infra

```bash
terraform destroy   # Supprime toutes les ressources créées
```

---

## 7. Monitoring et observabilité

### Monitoring local (démo)

La stack de monitoring locale se lance en une commande et ne nécessite pas de compte GCP :

```bash
cd docker
docker compose up -d
```

| Service | URL | Identifiants |
|---------|-----|--------------|
| Grafana | http://localhost:3000 | admin / quantis |
| Prometheus | http://localhost:9090 | - |

Le dashboard **Quantis - Infrastructure Monitoring** se charge automatiquement.

### Métriques surveillées

| Métrique | Source | Alerte |
|----------|--------|--------|
| Disponibilité des services | Prometheus `up` | < 1 = alerte critique |
| Durée de scrape | `scrape_duration_seconds` | > 1s = warning |
| Samples ingérés/s | `prometheus_tsdb_head_samples_appended_total` | Baseline |
| Erreurs Cloud Function | GCP Monitoring | > 0 erreur/heure |
| Latence Cloud Run Job | GCP Monitoring | > 120s = timeout |

---

## 8. KPIs calculés

| KPI | Formule | Catégorie | Unité |
|-----|---------|-----------|-------|
| `revenue` | Chiffre d'affaires brut | profitability | EUR |
| `gross_margin` | Résultat brut / CA | profitability | % |
| `operating_margin` | EBIT / CA | profitability | % |
| `net_margin` | Résultat net / CA | profitability | % |
| `total_assets` | Total actif bilan | balance | EUR |
| `equity` | Capitaux propres | balance | EUR |
| `long_term_debt` | Dettes long terme | balance | EUR |
| `current_ratio` | Actif court terme / Passif court terme | liquidity | ratio |
| `debt_to_equity` | Total dettes / Capitaux propres | solvency | ratio |
| `return_on_equity` | Résultat net / Capitaux propres | profitability | % |
