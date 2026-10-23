# Stock Portfolio & Market Analytics Database (PostgreSQL)

A personal project modeling a simplified stock trading platform and portfolio tracking system, fully contained in a single executable PostgreSQL script (finalproject.sql).

The main goal was to move beyond basic SELECT queries by practicing how to enforce trading business rules directly at the schema level and writing analytical queries for portfolio performance and operational risk.

---

## 1. Why Build This?
When working with financial and portfolio data, small errors (like negative cash balances or selling shares you do not own) quickly corrupt downstream reports. 

Instead of treating the database as just a passive storage table, I wanted to practice:
- Designing a normalized relational schema for market and user transaction data.
- Enforcing business rules natively using PostgreSQL functions and triggers.
- Writing analytical SQL to answer realistic portfolio and operational questions.

---

## 2. Business Rules Implemented
To ensure data stays clean before any analysis runs, the database natively handles key trading constraints:

- No Short Selling: A trigger (BEFORE INSERT OR UPDATE) checks current holdings in portfolio_holdings before executing a sell order.
- Sufficient Cash Check: Buying stocks automatically validates account balance and deducts transaction costs plus brokerage fees. Accounts cannot drop below zero via CHECK (balance >= 0).
- Account Ownership: Used composite foreign keys (account_id, investor_id) on trades to prevent orders from being booked into someone else's account.
- Locked Trade History: Once a trade is marked as completed or cancelled, triggers prevent further edits to maintain an accurate transaction log.

---

## 3. Database Schema
The database contains 10 tables covering reference data, user accounts, and trading activities.

![Database ERD](erd_diagram.png)

---

## 4. Key Analytical Queries
After setting up clean transactional data, I wrote queries to explore practical business questions:

1. Portfolio Concentration (HHI): Calculated the Herfindahl-Hirschman Index using window functions to identify investors with high concentration risk in single stocks.
2. Realized vs. Unrealized PnL: Replayed chronological trade history using a Recursive CTE to calculate moving weighted-average costs at each point of sale.
3. Dividend Eligibility: Reconciled cash dividends based on shares actually held on the declared date versus naive snapshot holdings.
4. Data Quality Audit: Queried for operational anomalies, such as trades dated after the latest market price snapshot or listed stocks missing price history.

---

## 5. Testing & Validation
The script includes automated test blocks to verify that the logic works as intended:
- Confirmed that automated triggers correctly block illegal sell orders and cross-account trades.
- Verified that transaction rollback (ROLLBACK) works properly when a transfer exceeds available funds.
- Reconciled final inventory: total holdings match the chronological net sum of all completed trades.

---
Author: VAN GIA BAO 
Contact: vgbao.24115@gmail.com 
