"""
Quantis - Générateur de données fictives
Produit income_statement.csv et balance_sheet.csv prêts à uploader sur GCS.
Usage : python scripts/generate_data.py
"""
import pandas as pd
import numpy as np
import os

SEED = 42
np.random.seed(SEED)

COMPANIES = ["SuperRetail A", "TechStart B", "ManuCorp C"]
YEARS = [2023, 2024]


def generate_income_statement(company: str, year: int) -> dict:
    revenues = max(500_000, np.random.normal(1_200_000, 150_000))
    cogs = revenues * np.random.uniform(0.50, 0.60)
    gross_profit = revenues - cogs
    sga = revenues * np.random.uniform(0.22, 0.28)
    depreciation = np.random.normal(40_000, 5_000)
    ebit = gross_profit - sga - depreciation
    interest_expense = np.random.normal(10_000, 2_000)
    ibt = ebit - interest_expense
    tax = max(0, ibt * np.random.uniform(0.23, 0.27))
    net_income = ibt - tax

    return {
        "Company": company, "Year": year,
        "Revenues": revenues,
        "Cost of Goods Sold (COGS)": cogs,
        "GROSS PROFIT": gross_profit,
        "Selling, General & Administrative (SG&A)": sga,
        "Depreciation & Amortization": depreciation,
        "OPERATING INCOME (EBIT)": ebit,
        "Interest Expense": interest_expense,
        "INCOME BEFORE TAX": ibt,
        "Income Tax": tax,
        "NET INCOME": net_income,
    }


def generate_balance_sheet(company: str, year: int, net_income: float) -> dict:
    ppe = np.random.normal(350_000, 40_000)
    intangibles = np.random.normal(50_000, 10_000)
    other_nca = np.random.normal(15_000, 3_000)
    non_current_assets = ppe + intangibles + other_nca

    inventories = np.random.normal(250_000, 30_000)
    receivables = np.random.normal(40_000, 10_000)
    cash = np.random.normal(120_000, 25_000)
    other_ca = np.random.normal(10_000, 2_000)
    current_assets = inventories + receivables + cash + other_ca
    total_assets = non_current_assets + current_assets

    long_term_debt = np.random.normal(200_000, 30_000)
    payables = np.random.normal(130_000, 20_000)
    other_cl = np.random.normal(30_000, 5_000)
    current_liabilities = payables + other_cl
    total_liabilities = long_term_debt + current_liabilities

    share_capital = 100_000
    retained_earnings = total_assets - total_liabilities - share_capital - net_income
    equity = share_capital + retained_earnings + net_income

    return {
        "Company": company, "Year": year,
        "Property, plant and equipment": ppe,
        "Intangible assets": intangibles,
        "Other non-current assets": other_nca,
        "NON-CURRENT ASSETS": non_current_assets,
        "Inventories": inventories,
        "Trade receivables": receivables,
        "Cash and cash equivalents": cash,
        "Other current assets": other_ca,
        "CURRENT ASSETS": current_assets,
        "TOTAL ASSETS": total_assets,
        "Share capital": share_capital,
        "Retained earnings": retained_earnings,
        "Net income": net_income,
        "EQUITY": equity,
        "Long-term debt": long_term_debt,
        "NON-CURRENT LIABILITIES": long_term_debt,
        "Trade payables": payables,
        "Other current liabilities": other_cl,
        "CURRENT LIABILITIES": current_liabilities,
        "TOTAL LIABILITIES": total_liabilities,
        "TOTAL EQUITY AND LIABILITIES": equity + total_liabilities,
    }


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    cdr_rows, bs_rows = [], []

    for company in COMPANIES:
        for year in YEARS:
            is_row = generate_income_statement(company, year)
            cdr_rows.append(is_row)
            bs_rows.append(generate_balance_sheet(company, year, is_row["NET INCOME"]))

    cdr_df = pd.DataFrame(cdr_rows).round(2)
    bs_df  = pd.DataFrame(bs_rows).round(2)

    # sep=, decimal=.  (cohérent avec main.py)
    cdr_path = os.path.join(out_dir, "income_statement.csv")
    bs_path  = os.path.join(out_dir, "balance_sheet.csv")
    cdr_df.to_csv(cdr_path, index=False, sep=",", decimal=".")
    bs_df.to_csv(bs_path,  index=False, sep=",", decimal=".")

    print(f"Généré : {cdr_path}  ({len(cdr_df)} lignes)")
    print(f"Généré : {bs_path}   ({len(bs_df)} lignes)")
    print("\nAperçu compte de résultat :")
    print(cdr_df[["Company", "Year", "Revenues", "NET INCOME"]].to_string(index=False))


if __name__ == "__main__":
    main()
