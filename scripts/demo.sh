#!/usr/bin/env bash
# =============================================================================
# Quantis - Script de démonstration (pour vidéo Loom)
# Lance Grafana + Prometheus, génère des données, simule le pipeline ETL
# Usage : bash scripts/demo.sh
# =============================================================================

set -e

BOLD="\033[1m"
BLUE="\033[34m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

banner() {
  echo ""
  echo -e "${BLUE}${BOLD}============================================================${RESET}"
  echo -e "${BLUE}${BOLD}  $1${RESET}"
  echo -e "${BLUE}${BOLD}============================================================${RESET}"
  echo ""
}

step() {
  echo -e "${CYAN}${BOLD}>>> $1${RESET}"
}

ok() {
  echo -e "${GREEN}✓ $1${RESET}"
}

warn() {
  echo -e "${YELLOW}⚠ $1${RESET}"
}

# =============================================================================
# 0. Vérifications
# =============================================================================
banner "Quantis - Infrastructure Demo"
echo -e "  ${BOLD}Pipeline :${RESET} GCS → Pub/Sub → Cloud Function → Cloud Run Job → BigQuery"
echo -e "  ${BOLD}Monitoring :${RESET} Prometheus + Grafana"
echo ""

step "Vérification de Docker..."
if ! command -v docker &>/dev/null; then
  echo "Docker n'est pas installé. Télécharge Docker Desktop : https://www.docker.com/products/docker-desktop"
  exit 1
fi
if ! docker info &>/dev/null; then
  echo "Docker Desktop n'est pas démarré. Lance-le et relance ce script."
  exit 1
fi
ok "Docker disponible : $(docker --version)"

step "Vérification de Python..."
if ! command -v python3 &>/dev/null && ! command -v python &>/dev/null; then
  warn "Python non trouvé - la simulation ETL sera ignorée"
  PYTHON=""
else
  PYTHON=$(command -v python3 || command -v python)
  ok "Python disponible : $($PYTHON --version)"
fi

# =============================================================================
# 1. Lancer le stack monitoring (Prometheus + Grafana)
# =============================================================================
banner "Etape 1/4 - Lancement du stack monitoring"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$ROOT_DIR/docker"

step "Lancement de Prometheus + Grafana via Docker Compose..."
cd "$DOCKER_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo ""
step "Attente démarrage des services (15 secondes)..."
sleep 15

# Vérification Grafana
if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health | grep -q "200"; then
  ok "Grafana opérationnel : http://localhost:3000  (admin / quantis)"
else
  warn "Grafana en cours de démarrage, attendre encore 10 secondes..."
  sleep 10
fi

# Vérification Prometheus
if curl -s -o /dev/null -w "%{http_code}" http://localhost:9090/-/ready | grep -q "200"; then
  ok "Prometheus opérationnel : http://localhost:9090"
else
  warn "Prometheus toujours en démarrage..."
fi

# =============================================================================
# 2. Générer les données de test
# =============================================================================
banner "Etape 2/4 - Generation des donnees financieres de test"

cd "$ROOT_DIR"
step "Génération des CSV (3 entreprises x 2 années)..."

if [ -n "$PYTHON" ]; then
  $PYTHON scripts/generate_data.py
  ok "CSV générés : income_statement.csv et balance_sheet.csv"
else
  warn "Python non disponible - création de CSV exemples..."
  cat > income_statement.csv << 'CSVEOF'
Company,Year,Revenues,Cost of Goods Sold (COGS),GROSS PROFIT,Selling General & Administrative (SG&A),Depreciation & Amortization,OPERATING INCOME (EBIT),Interest Expense,INCOME BEFORE TAX,Income Tax,NET INCOME
SuperRetail A,2024,1250000,687500,562500,312500,42000,208000,10500,197500,49375,148125
TechStart B,2024,980000,539000,441000,244500,38000,158500,9800,148700,37175,111525
CSVEOF
  ok "CSV exemple créé"
fi

# =============================================================================
# 3. Simuler le pipeline ETL (sans GCP)
# =============================================================================
banner "Etape 3/4 - Simulation pipeline ETL Quantis"

step "Simulation du traitement ETL (calcul des KPIs financiers)..."
echo ""

if [ -n "$PYTHON" ]; then
$PYTHON << 'PYEOF'
import pandas as pd
import datetime as dt

print("  [PIPELINE] Lecture income_statement.csv...")
try:
    cdr = pd.read_csv("income_statement.csv")
    print(f"  [OK] {len(cdr)} lignes chargées depuis income_statement.csv")
except:
    print("  [INFO] Utilisation de données de démonstration")
    cdr = pd.DataFrame([
        {"Company": "SuperRetail A", "Year": 2024, "Revenues": 1250000,
         "GROSS PROFIT": 562500, "OPERATING INCOME (EBIT)": 208000, "NET INCOME": 148125,
         "Cost of Goods Sold (COGS)": 687500, "Selling, General & Administrative (SG&A)": 312500,
         "Depreciation & Amortization": 42000, "Interest Expense": 10500,
         "INCOME BEFORE TAX": 197500, "Income Tax": 49375},
        {"Company": "TechStart B", "Year": 2024, "Revenues": 980000,
         "GROSS PROFIT": 441000, "OPERATING INCOME (EBIT)": 158500, "NET INCOME": 111525,
         "Cost of Goods Sold (COGS)": 539000, "Selling, General & Administrative (SG&A)": 244500,
         "Depreciation & Amortization": 38000, "Interest Expense": 9800,
         "INCOME BEFORE TAX": 148700, "Income Tax": 37175},
    ])

print()
print("  [PIPELINE] Calcul des KPIs financiers...")
print()

results = []
for _, r in cdr.iterrows():
    company = r["Company"]
    year = int(r["Year"])
    rev = float(r["Revenues"])
    gp  = float(r["GROSS PROFIT"])
    ebit = float(r["OPERATING INCOME (EBIT)"])
    ni   = float(r["NET INCOME"])

    kpis = {
        "revenue":          rev,
        "gross_margin":     round(gp / rev * 100, 2),
        "operating_margin": round(ebit / rev * 100, 2),
        "net_margin":       round(ni / rev * 100, 2),
    }

    print(f"  ┌─ {company} ({year}) ──────────────────────────────────")
    print(f"  │  Revenue          : {rev:>14,.0f} EUR")
    print(f"  │  Gross margin     : {kpis['gross_margin']:>14.1f} %")
    print(f"  │  Operating margin : {kpis['operating_margin']:>14.1f} %")
    print(f"  │  Net margin       : {kpis['net_margin']:>14.1f} %")
    print(f"  └───────────────────────────────────────────────────────")
    print()
    results.append({"company": company, "year": year, **kpis})

df_out = pd.DataFrame(results)
print(f"  [OK] {len(df_out) * 4} KPIs calculés pour {len(df_out)} entreprise(s)")
print()
print("  [PIPELINE] → En production : upload vers BigQuery (quantis_analytics.financial_kpis)")
print("  [PIPELINE] → En production : Grafana interroge BigQuery et affiche les dashboards")
PYEOF
fi

# =============================================================================
# 4. Résumé et URLs
# =============================================================================
banner "Etape 4/4 - Infrastructure deploye"

echo -e "  ${BOLD}MONITORING LOCAL${RESET}"
echo -e "  ┌──────────────────────────────────────────────────────┐"
echo -e "  │  Grafana    : ${GREEN}http://localhost:3000${RESET}                  │"
echo -e "  │               Login : admin / quantis                │"
echo -e "  │  Prometheus : ${GREEN}http://localhost:9090${RESET}                  │"
echo -e "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "  ${BOLD}INFRASTRUCTURE GCP (via Terraform)${RESET}"
echo -e "  ┌──────────────────────────────────────────────────────┐"
echo -e "  │  GCS Buckets  : balance-sheets, income-statements    │"
echo -e "  │  Pub/Sub      : quantis-csv-uploads                  │"
echo -e "  │  Cloud Func   : quantis-trigger-job                  │"
echo -e "  │  Cloud Run    : quantis-kpi-job (ETL + KPIs)         │"
echo -e "  │  BigQuery     : quantis_analytics.financial_kpis     │"
echo -e "  └──────────────────────────────────────────────────────┘"
echo ""
echo -e "  ${BOLD}STAR SCHEMA BigQuery${RESET}"
echo -e "  financial_kpis : company_name | report_date | kpi_name | kpi_value | kpi_category"
echo ""

step "Ouverture automatique de Grafana dans le navigateur..."
if command -v start &>/dev/null; then
  start http://localhost:3000
elif command -v xdg-open &>/dev/null; then
  xdg-open http://localhost:3000
elif command -v open &>/dev/null; then
  open http://localhost:3000
fi

echo ""
ok "Demo prête. Enregistre maintenant avec Loom !"
echo ""
echo -e "  Pour arrêter les services : ${BOLD}docker compose -f docker/docker-compose.yml down${RESET}"
echo ""
