--SECTION 1: Schemas--
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_portfolio_report CASCADE;
DROP VIEW IF EXISTS vw_investor_portfolio CASCADE;
DROP VIEW IF EXISTS vw_top_performing_stocks CASCADE;

DROP TABLE IF EXISTS audit_log           CASCADE;
DROP TABLE IF EXISTS dividends           CASCADE;
DROP TABLE IF EXISTS daily_market_prices CASCADE;
DROP TABLE IF EXISTS portfolio_holdings  CASCADE;
DROP TABLE IF EXISTS trades              CASCADE;
DROP TABLE IF EXISTS accounts            CASCADE;
DROP TABLE IF EXISTS stocks              CASCADE;
DROP TABLE IF EXISTS investors           CASCADE;
DROP TABLE IF EXISTS exchanges           CASCADE;
DROP TABLE IF EXISTS sectors             CASCADE;

-- 1. Sectors
CREATE TABLE sectors (
    sector_id   SERIAL       PRIMARY KEY,
    sector_name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT
);

-- 2. Exchanges
CREATE TABLE exchanges (
    exchange_id   SERIAL       PRIMARY KEY,
    exchange_name VARCHAR(100) NOT NULL UNIQUE,
    country       VARCHAR(100) NOT NULL,
    currency      CHAR(3)      NOT NULL,
    timezone      VARCHAR(50)  NOT NULL DEFAULT 'Asia/Ho_Chi_Minh'
);

-- 3. Stocks
CREATE TABLE stocks (
    stock_id     SERIAL       PRIMARY KEY,
    stock_symbol VARCHAR(10)  NOT NULL UNIQUE,
    company_name VARCHAR(200) NOT NULL,
    sector_id    INT          NOT NULL,
    exchange_id  INT          NOT NULL,
    listing_date DATE         NOT NULL,
    status       VARCHAR(10)  NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'suspended', 'delisted')),
    CONSTRAINT fk_stocks_sector   FOREIGN KEY (sector_id)   REFERENCES sectors(sector_id),
    CONSTRAINT fk_stocks_exchange FOREIGN KEY (exchange_id) REFERENCES exchanges(exchange_id)
);

-- 4. Investors
CREATE TABLE investors (
    investor_id   SERIAL       PRIMARY KEY,
    full_name     VARCHAR(200) NOT NULL,
    email         VARCHAR(150) NOT NULL UNIQUE,
    phone         VARCHAR(20),
    date_of_birth DATE         CHECK (date_of_birth < CURRENT_DATE),
    created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 5. Accounts
CREATE TABLE accounts (
    account_id   SERIAL         PRIMARY KEY,
    investor_id  INT            NOT NULL,
    account_type VARCHAR(10)    NOT NULL DEFAULT 'cash'
                                CHECK (account_type IN ('cash', 'margin')),
    balance      NUMERIC(18, 2) NOT NULL DEFAULT 0.00 CHECK (balance >= 0),
    created_at   TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_account_investor  UNIQUE (account_id, investor_id),
    CONSTRAINT fk_accounts_investor FOREIGN KEY (investor_id) REFERENCES investors(investor_id)
);

-- 6. Trades
-- Composite FK (account_id, investor_id) prevents cross-account trading
CREATE TABLE trades (
    trade_id        SERIAL         PRIMARY KEY,
    investor_id     INT            NOT NULL,
    stock_id        INT            NOT NULL,
    account_id      INT            NOT NULL,
    trade_type      VARCHAR(4)     NOT NULL CHECK (trade_type IN ('buy', 'sell')),
    quantity        INT            NOT NULL CHECK (quantity > 0),
    price_per_share NUMERIC(12, 2) NOT NULL CHECK (price_per_share > 0),
    trade_date      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fee             NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (fee >= 0),
    status          VARCHAR(10)    NOT NULL DEFAULT 'completed'
                                   CHECK (status IN ('pending', 'completed', 'cancelled')),
    CONSTRAINT fk_trades_investor         FOREIGN KEY (investor_id) REFERENCES investors(investor_id),
    CONSTRAINT fk_trades_stock            FOREIGN KEY (stock_id)    REFERENCES stocks(stock_id),
    CONSTRAINT fk_trades_account_investor FOREIGN KEY (account_id, investor_id)
                                          REFERENCES accounts(account_id, investor_id)
);

-- 7. Portfolio Holdings (Updated automatically via triggers on trades)
CREATE TABLE portfolio_holdings (
    holding_id   SERIAL         PRIMARY KEY,
    investor_id  INT            NOT NULL,
    stock_id     INT            NOT NULL,
    quantity     INT            NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    average_cost NUMERIC(12, 2) NOT NULL CHECK (average_cost >= 0),
    last_updated TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_investor_stock    UNIQUE (investor_id, stock_id),
    CONSTRAINT fk_holdings_investor FOREIGN KEY (investor_id) REFERENCES investors(investor_id),
    CONSTRAINT fk_holdings_stock    FOREIGN KEY (stock_id)    REFERENCES stocks(stock_id)
);

-- 8. Daily Market Prices
CREATE TABLE daily_market_prices (
    price_id    SERIAL         PRIMARY KEY,
    stock_id    INT            NOT NULL,
    price_date  DATE           NOT NULL,
    open_price  NUMERIC(12, 2) NOT NULL CHECK (open_price  > 0),
    close_price NUMERIC(12, 2) NOT NULL CHECK (close_price > 0),
    high_price  NUMERIC(12, 2) NOT NULL CHECK (high_price  > 0),
    low_price   NUMERIC(12, 2) NOT NULL CHECK (low_price   > 0),
    volume      BIGINT         NOT NULL CHECK (volume >= 0),
    CONSTRAINT chk_price_ohlc CHECK (
        high_price >= GREATEST(open_price, close_price, low_price)
        AND low_price <= LEAST(open_price, close_price, high_price)
    ),
    CONSTRAINT uq_stock_date   UNIQUE (stock_id, price_date),
    CONSTRAINT fk_prices_stock FOREIGN KEY (stock_id) REFERENCES stocks(stock_id)
);

-- 9. Dividends
CREATE TABLE dividends (
    dividend_id      SERIAL         PRIMARY KEY,
    stock_id         INT            NOT NULL,
    declared_date    DATE           NOT NULL,
    payment_date     DATE           NOT NULL,
    amount_per_share NUMERIC(10, 4) NOT NULL CHECK (amount_per_share > 0),
    dividend_type    VARCHAR(10)    NOT NULL DEFAULT 'cash'
                                    CHECK (dividend_type IN ('cash', 'stock')),
    CONSTRAINT chk_dividend_dates CHECK (payment_date >= declared_date),
    CONSTRAINT fk_dividends_stock FOREIGN KEY (stock_id) REFERENCES stocks(stock_id)
);

-- 10. Audit Log
CREATE TABLE audit_log (
    log_id      SERIAL      PRIMARY KEY,
    log_time    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    action_type VARCHAR(20) NOT NULL,
    table_name  VARCHAR(50) NOT NULL,
    description TEXT,
    status      VARCHAR(20) NOT NULL
);

-- Indexes for query optimization
CREATE INDEX idx_trades_investor_date ON trades(investor_id, trade_date DESC);
CREATE INDEX idx_trades_stock_date    ON trades(stock_id, trade_date DESC);
CREATE INDEX idx_trades_trade_date    ON trades(trade_date DESC);
CREATE INDEX idx_stocks_sector_id     ON stocks(sector_id);
CREATE INDEX idx_dividends_stock_date ON dividends(stock_id, declared_date);
-----------------------------------------------------------------------------
-- SECTION 2: Trigger, Funtion

-- 1. Calculate trading fee (0.15% brokerage, min 10,000 VND + 0.10% sell tax)
CREATE OR REPLACE FUNCTION fn_calculate_trading_fee(
    p_trade_type VARCHAR,
    p_quantity INT,
    p_price_per_share NUMERIC
)
RETURNS NUMERIC AS $func$
DECLARE
    v_trade_val     NUMERIC;
    v_brokerage_fee NUMERIC;
    v_tax_fee       NUMERIC;
BEGIN
    IF p_quantity <= 0 OR p_price_per_share <= 0 THEN
        RAISE EXCEPTION 'Quantity and price must be greater than 0.';
    END IF;

    v_trade_val     := p_quantity * p_price_per_share;
    v_brokerage_fee := GREATEST(v_trade_val * 0.0015, 10000);
    v_tax_fee       := CASE WHEN LOWER(p_trade_type) = 'sell' THEN v_trade_val * 0.001 ELSE 0 END;

    RETURN ROUND(v_brokerage_fee + v_tax_fee, 0);
END;
$func$ LANGUAGE plpgsql IMMUTABLE;


-- 2. Calculate portfolio ROI for a given investor
CREATE OR REPLACE FUNCTION fn_calculate_portfolio_roi(p_investor_id INT)
RETURNS TABLE (
    stock_symbol   VARCHAR,
    quantity_held  INT,
    average_cost   NUMERIC,
    current_price  NUMERIC,
    cost_basis     NUMERIC,
    current_value  NUMERIC,
    unrealized_pnl NUMERIC,
    roi_percent    NUMERIC,
    weight_percent NUMERIC
) AS $func$
DECLARE
    v_total_val NUMERIC;
BEGIN
    WITH latest_prices AS (
        SELECT DISTINCT ON (stock_id) stock_id, close_price
        FROM daily_market_prices
        ORDER BY stock_id, price_date DESC
    )
    SELECT COALESCE(SUM(ph.quantity * COALESCE(lp.close_price, ph.average_cost)), 0)
    INTO v_total_val
    FROM portfolio_holdings ph
    LEFT JOIN latest_prices lp ON lp.stock_id = ph.stock_id
    WHERE ph.investor_id = p_investor_id;

    RETURN QUERY
    WITH latest_prices AS (
        SELECT DISTINCT ON (dmp.stock_id) dmp.stock_id, dmp.close_price
        FROM daily_market_prices dmp
        ORDER BY dmp.stock_id, dmp.price_date DESC
    )
    SELECT
        s.stock_symbol,
        ph.quantity AS quantity_held,
        ROUND(ph.average_cost, 2) AS average_cost,
        ROUND(COALESCE(lp.close_price, ph.average_cost), 2) AS current_price,
        ROUND(ph.quantity * ph.average_cost, 0) AS cost_basis,
        ROUND(ph.quantity * COALESCE(lp.close_price, ph.average_cost), 0) AS current_value,
        ROUND(ph.quantity * (COALESCE(lp.close_price, ph.average_cost) - ph.average_cost), 0) AS unrealized_pnl,
        ROUND(
            (COALESCE(lp.close_price, ph.average_cost) - ph.average_cost)
            / NULLIF(ph.average_cost, 0) * 100,
            2
        ) AS roi_percent,
        ROUND(
            (ph.quantity * COALESCE(lp.close_price, ph.average_cost))
            / NULLIF(v_total_val, 0) * 100,
            2
        ) AS weight_percent
    FROM portfolio_holdings ph
    JOIN stocks s ON s.stock_id = ph.stock_id
    LEFT JOIN latest_prices lp ON lp.stock_id = ph.stock_id
    WHERE ph.investor_id = p_investor_id
    ORDER BY current_value DESC;
END;
$func$ LANGUAGE plpgsql STABLE;


-- 3. Calculate dividend income based on holdings as of declared_date
CREATE OR REPLACE FUNCTION fn_calculate_dividend_income(p_investor_id INT, p_year INT)
RETURNS TABLE (
    stock_symbol      VARCHAR,
    declared_date     DATE,
    payment_date      DATE,
    dividend_type     VARCHAR,
    shares_eligible   INT,
    amount_per_share  NUMERIC,
    cash_dividend_vnd NUMERIC
) AS $func$
BEGIN
    RETURN QUERY
    WITH eligible_holdings AS (
        SELECT
            d.dividend_id,
            d.stock_id,
            d.declared_date,
            d.payment_date,
            d.dividend_type,
            d.amount_per_share,
            COALESCE(SUM(
                CASE
                    WHEN t.trade_type = 'buy'  THEN t.quantity
                    WHEN t.trade_type = 'sell' THEN -t.quantity
                    ELSE 0
                END
            ), 0)::INT AS net_shares
        FROM dividends d
        JOIN trades t
          ON t.stock_id = d.stock_id
         AND t.investor_id = p_investor_id
         AND t.status = 'completed'
         AND t.trade_date::DATE <= d.declared_date
        WHERE EXTRACT(YEAR FROM d.payment_date) = p_year
        GROUP BY
            d.dividend_id, d.stock_id, d.declared_date,
            d.payment_date, d.dividend_type, d.amount_per_share
    )
    SELECT
        s.stock_symbol,
        eh.declared_date,
        eh.payment_date,
        eh.dividend_type,
        eh.net_shares AS shares_eligible,
        eh.amount_per_share,
        CASE
            WHEN eh.dividend_type = 'cash'
            THEN ROUND(eh.net_shares * eh.amount_per_share, 0)
            ELSE 0::NUMERIC
        END AS cash_dividend_vnd
    FROM eligible_holdings eh
    JOIN stocks s ON s.stock_id = eh.stock_id
    WHERE eh.net_shares > 0
    ORDER BY eh.payment_date, s.stock_symbol;
END;
$func$ LANGUAGE plpgsql STABLE;


-- 4. Trigger Function: Pre-trade validation and short-selling prevention
CREATE OR REPLACE FUNCTION fn_prevent_oversell()
RETURNS TRIGGER AS $func$
DECLARE
    v_current_qty  INT;
    v_owner_id     INT;
    v_stock_status VARCHAR(10);
BEGIN
    -- Block updates to completed or cancelled trades
    IF TG_OP = 'UPDATE' AND OLD.status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'Cannot modify trade % because status is already %.',
            OLD.trade_id, OLD.status;
    END IF;

    -- Verify account ownership
    SELECT investor_id INTO v_owner_id
    FROM accounts
    WHERE account_id = NEW.account_id;

    IF v_owner_id IS NULL OR v_owner_id != NEW.investor_id THEN
        RAISE EXCEPTION 'Account % does not belong to investor %.',
            NEW.account_id, NEW.investor_id;
    END IF;

    -- Verify stock is active
    SELECT status INTO v_stock_status
    FROM stocks
    WHERE stock_id = NEW.stock_id;

    IF v_stock_status IS NULL OR v_stock_status != 'active' THEN
        RAISE EXCEPTION 'Stock % is not active for trading (status: %).',
            NEW.stock_id, COALESCE(v_stock_status, 'UNKNOWN');
    END IF;

    -- Auto-calculate fee if not provided or if pending order details changed
    IF NEW.fee IS NULL
       OR NEW.fee = 0
       OR (
           TG_OP = 'UPDATE'
           AND NEW.fee = OLD.fee
           AND (NEW.quantity != OLD.quantity OR NEW.price_per_share != OLD.price_per_share OR NEW.trade_type != OLD.trade_type)
       )
    THEN
        NEW.fee := fn_calculate_trading_fee(NEW.trade_type, NEW.quantity, NEW.price_per_share);
    END IF;

    -- Check holdings for completed sell orders
    IF NEW.status != 'completed' OR NEW.trade_type != 'sell' THEN
        RETURN NEW;
    END IF;

    SELECT quantity INTO v_current_qty
    FROM portfolio_holdings
    WHERE investor_id = NEW.investor_id AND stock_id = NEW.stock_id;

    IF v_current_qty IS NULL OR v_current_qty < NEW.quantity THEN
        RAISE EXCEPTION 'Oversell rejected: Attempted to sell % shares, but only % available (investor_id=%, stock_id=%).',
            NEW.quantity, COALESCE(v_current_qty, 0), NEW.investor_id, NEW.stock_id;
    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE plpgsql;


-- 5. Trigger Function: Update portfolio holdings upon trade completion
CREATE OR REPLACE FUNCTION fn_update_portfolio_holdings()
RETURNS TRIGGER AS $func$
DECLARE
    v_qty     INT;
    v_avg     NUMERIC;
    v_new_avg NUMERIC;
BEGIN
    IF NOT (
        (TG_OP = 'INSERT' AND NEW.status = 'completed') OR
        (TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'completed')
    ) THEN
        RETURN NEW;
    END IF;

    SELECT quantity, average_cost INTO v_qty, v_avg
    FROM portfolio_holdings
    WHERE investor_id = NEW.investor_id AND stock_id = NEW.stock_id
    FOR UPDATE;

    IF NEW.trade_type = 'buy' THEN
        IF v_qty IS NULL THEN
            INSERT INTO portfolio_holdings (investor_id, stock_id, quantity, average_cost, last_updated)
            VALUES (NEW.investor_id, NEW.stock_id, NEW.quantity, NEW.price_per_share, NEW.trade_date);
        ELSE
            v_new_avg := ROUND((v_qty * v_avg + NEW.quantity * NEW.price_per_share) / (v_qty + NEW.quantity), 2);
            UPDATE portfolio_holdings
            SET quantity     = quantity + NEW.quantity,
                average_cost = v_new_avg,
                last_updated = GREATEST(last_updated, NEW.trade_date)
            WHERE investor_id = NEW.investor_id AND stock_id = NEW.stock_id;
        END IF;
    ELSIF NEW.trade_type = 'sell' THEN
        IF (v_qty - NEW.quantity) = 0 THEN
            DELETE FROM portfolio_holdings
            WHERE investor_id = NEW.investor_id AND stock_id = NEW.stock_id;
        ELSE
            UPDATE portfolio_holdings
            SET quantity     = quantity - NEW.quantity,
                last_updated = GREATEST(last_updated, NEW.trade_date)
            WHERE investor_id = NEW.investor_id AND stock_id = NEW.stock_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE plpgsql;


-- 6. Trigger Function: Update account cash/margin balance upon trade completion
CREATE OR REPLACE FUNCTION fn_update_account_balance()
RETURNS TRIGGER AS $func$
DECLARE
    v_net_amount NUMERIC;
    v_balance    NUMERIC;
BEGIN
    IF NOT (
        (TG_OP = 'INSERT' AND NEW.status = 'completed') OR
        (TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'completed')
    ) THEN
        RETURN NEW;
    END IF;

    SELECT balance INTO v_balance
    FROM accounts
    WHERE account_id = NEW.account_id
    FOR UPDATE;

    IF NEW.trade_type = 'buy' THEN
        v_net_amount := NEW.quantity * NEW.price_per_share + NEW.fee;
        IF v_balance < v_net_amount THEN
            RAISE EXCEPTION 'Insufficient balance: Available % VND, required % VND (account_id=%).',
                v_balance, v_net_amount, NEW.account_id;
        END IF;
        UPDATE accounts
        SET balance = balance - v_net_amount
        WHERE account_id = NEW.account_id;
    ELSE
        v_net_amount := NEW.quantity * NEW.price_per_share - NEW.fee;
        UPDATE accounts
        SET balance = balance + v_net_amount
        WHERE account_id = NEW.account_id;
    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE plpgsql;


-- Attach triggers to trades table
DROP TRIGGER IF EXISTS trg_prevent_oversell       ON trades;
DROP TRIGGER IF EXISTS trg_update_holdings        ON trades;
DROP TRIGGER IF EXISTS trg_update_account_balance ON trades;

CREATE TRIGGER trg_prevent_oversell
BEFORE INSERT OR UPDATE ON trades
FOR EACH ROW EXECUTE FUNCTION fn_prevent_oversell();

CREATE TRIGGER trg_update_account_balance
AFTER INSERT OR UPDATE ON trades
FOR EACH ROW EXECUTE FUNCTION fn_update_account_balance();

CREATE TRIGGER trg_update_holdings
AFTER INSERT OR UPDATE ON trades
FOR EACH ROW EXECUTE FUNCTION fn_update_portfolio_holdings();

---------------------------------------------------------------------
--SECTION 3: Data

INSERT INTO sectors (sector_name, description) VALUES
('Ngân hàng',            'Các tổ chức tín dụng, ngân hàng thương mại'),
('Bất động sản',         'Đầu tư, phát triển và kinh doanh bất động sản'),
('Công nghệ thông tin',  'Phần mềm, dịch vụ CNTT, viễn thông'),
('Hàng tiêu dùng',       'Thực phẩm, đồ uống, hàng thiết yếu'),
('Năng lượng',           'Điện, dầu khí, năng lượng tái tạo'),
('Sản xuất công nghiệp', 'Thép, xi măng, vật liệu xây dựng'),
('Dược phẩm & Y tế',     'Sản xuất thuốc, thiết bị y tế, bệnh viện'),
('Vận tải & Logistics',  'Hàng không, cảng biển, vận chuyển hàng hóa');

INSERT INTO exchanges (exchange_name, country, currency, timezone) VALUES
('HOSE',   'Việt Nam', 'VND', 'Asia/Ho_Chi_Minh'),
('HNX',    'Việt Nam', 'VND', 'Asia/Ho_Chi_Minh'),
('UPCOM',  'Việt Nam', 'VND', 'Asia/Ho_Chi_Minh'),
('NYSE',   'Hoa Kỳ',   'USD', 'America/New_York'),
('NASDAQ', 'Hoa Kỳ',   'USD', 'America/New_York');

INSERT INTO stocks (stock_symbol, company_name, sector_id, exchange_id, listing_date, status) VALUES
('VCB', 'Ngân hàng TMCP Ngoại thương Việt Nam (Vietcombank)',         1, 1, '2009-06-30', 'active'),
('BID', 'Ngân hàng TMCP Đầu tư và Phát triển Việt Nam (BIDV)',        1, 1, '2014-01-24', 'active'),
('CTG', 'Ngân hàng TMCP Công thương Việt Nam (VietinBank)',           1, 1, '2009-07-16', 'active'),
('TCB', 'Ngân hàng TMCP Kỹ thương Việt Nam (Techcombank)',            1, 1, '2018-06-04', 'active'),
('MBB', 'Ngân hàng TMCP Quân đội (MBBank)',                           1, 1, '2011-11-01', 'active'),
('VIC', 'Tập đoàn Vingroup',                                          2, 1, '2012-01-19', 'active'),
('VHM', 'Công ty CP Vinhomes',                                        2, 1, '2018-05-17', 'active'),
('NVL', 'Công ty CP Tập đoàn Đầu tư Địa ốc No Va',                    2, 1, '2016-10-04', 'active'),
('FPT', 'Công ty CP FPT',                                             3, 1, '2006-12-13', 'active'),
('CMG', 'Công ty CP Tập đoàn Công nghệ CMC',                          3, 2, '2006-11-15', 'active'),
('VNM', 'Công ty CP Sữa Việt Nam (Vinamilk)',                         4, 1, '2006-01-19', 'active'),
('MSN', 'Công ty CP Tập đoàn Masan',                                  4, 1, '2009-11-05', 'active'),
('SAB', 'Tổng Công ty CP Bia - Rượu - NGK Sài Gòn (Sabeco)',          4, 1, '2016-12-06', 'active'),
('GAS', 'Tổng Công ty Khí Việt Nam - CTCP (PV GAS)',                  5, 1, '2012-05-21', 'active'),
('POW', 'Tổng Công ty Điện lực Dầu khí Việt Nam - CTCP',              5, 1, '2019-03-05', 'active'),
('HPG', 'Công ty CP Tập đoàn Hòa Phát',                               6, 1, '2007-11-15', 'active'),
('VCS', 'Công ty CP Vicostone',                                       6, 2, '2010-07-08', 'active'),
('DHG', 'Công ty CP Dược Hậu Giang',                                  7, 1, '2006-12-21', 'active'),
('HVN', 'Tổng Công ty Hàng không Việt Nam - CTCP (Vietnam Airlines)', 8, 1, '2019-01-02', 'active'),
('GMD', 'Công ty CP Gemadept',                                        8, 1, '2002-06-14', 'active');

INSERT INTO investors (full_name, email, phone, date_of_birth, created_at) VALUES
('Nguyễn Văn An',  'nguyen.van.an@gmail.com',   '0901234567', '1985-03-15', '2022-01-10 08:30:00'),
('Trần Thị Bình',  'tran.thi.binh@gmail.com',   '0912345678', '1990-07-22', '2022-03-05 09:15:00'),
('Lê Minh Cường',  'le.minh.cuong@yahoo.com',   '0923456789', '1978-11-30', '2021-11-20 14:00:00'),
('Phạm Thị Dung',  'pham.thi.dung@outlook.com', '0934567890', '1995-02-14', '2023-01-15 10:30:00'),
('Hoàng Văn Em',   'hoang.van.em@gmail.com',    '0945678901', '1988-09-08', '2022-06-01 11:00:00'),
('Vũ Thị Phương',  'vu.thi.phuong@gmail.com',   '0956789012', '1992-05-25', '2023-04-20 16:45:00'),
('Đặng Quốc Hùng', 'dang.quoc.hung@gmail.com',  '0967890123', '1975-12-01', '2021-08-15 08:00:00'),
('Bùi Thị Lan',    'bui.thi.lan@gmail.com',     '0978901234', '1998-04-18', '2023-09-10 13:30:00'),
('Ngô Đình Mạnh',  'ngo.dinh.manh@gmail.com',   '0989012345', '1983-08-27', '2022-02-28 09:00:00'),
('Lý Thị Ngọc',    'ly.thi.ngoc@gmail.com',     '0990123456', '1996-01-05', '2024-01-03 15:00:00');

INSERT INTO accounts (investor_id, account_type, balance, created_at) VALUES
(1,  'cash',   1028879430.00, '2022-01-10 08:30:00'),
(1,  'margin',  548298250.00, '2022-06-15 10:00:00'),
(2,  'cash',    462027050.00, '2022-03-05 09:15:00'),
(3,  'cash',   1537815450.00, '2021-11-20 14:00:00'),
(3,  'margin',  800000000.00, '2022-01-10 09:00:00'),
(4,  'cash',    304154000.00, '2023-01-15 10:30:00'),
(5,  'cash',    779449270.00, '2022-06-01 11:00:00'),
(5,  'margin',  400000000.00, '2022-09-15 14:00:00'),
(6,  'cash',    455475300.00, '2023-04-20 16:45:00'),
(7,  'cash',   3274273500.00, '2021-08-15 08:00:00'),
(7,  'margin', 1500000000.00, '2021-10-01 09:30:00'),
(8,  'cash',    259364200.00, '2023-09-10 13:30:00'),
(9,  'cash',    612762600.00, '2022-02-28 09:00:00'),
(10, 'cash',    294114000.00, '2024-01-03 15:00:00');

-- Historical trades (2023)
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 1, 1, 'buy', 1000, 89500, '2023-01-10 09:15:00', 89500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 9, 1, 'buy', 2000, 75200, '2023-01-15 10:30:00', 150400, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (3, 6, 4, 'buy', 500, 65300, '2023-01-20 14:00:00', 32650, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (7, 16, 10, 'buy', 5000, 23100, '2023-01-25 09:45:00', 115500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (5, 11, 7, 'buy', 800, 72400, '2023-01-28 11:00:00', 57920, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (2, 4, 3, 'buy', 1500, 31500, '2023-02-06 09:30:00', 47250, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (9, 1, 13, 'buy', 700, 88000, '2023-02-10 10:00:00', 61600, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (7, 14, 10, 'buy', 2000, 95500, '2023-02-15 14:30:00', 191000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 7, 1, 'buy', 300, 52100, '2023-02-20 09:15:00', 15630, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (3, 12, 4, 'buy', 1000, 78300, '2023-02-25 11:45:00', 78300, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (5, 5, 7, 'buy', 2000, 22800, '2023-03-05 09:00:00', 45600, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (6, 9, 9, 'buy', 1000, 77500, '2023-03-10 10:30:00', 77500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (4, 11, 6, 'buy', 500, 71000, '2023-03-15 14:00:00', 35500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (7, 16, 10, 'buy', 3000, 24500, '2023-03-20 09:30:00', 73500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (8, 18, 12, 'buy', 600, 98000, '2023-03-25 11:00:00', 58800, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 1, 1, 'sell', 500, 95000, '2023-04-05 10:00:00', 47500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (9, 16, 13, 'buy', 2000, 26000, '2023-04-10 09:15:00', 52000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (2, 4, 3, 'sell', 500, 35200, '2023-04-15 14:30:00', 17600, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (3, 6, 4, 'sell', 200, 70000, '2023-04-20 10:00:00', 14000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (5, 11, 7, 'buy', 500, 69500, '2023-04-25 11:30:00', 34750, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (7, 1, 10, 'buy', 2000, 91000, '2023-05-05 09:00:00', 182000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (6, 14, 9, 'buy', 500, 98000, '2023-05-12 10:30:00', 49000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 9, 1, 'sell', 1000, 88000, '2023-05-20 14:00:00', 88000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (4, 5, 6, 'buy', 3000, 21500, '2023-06-05 09:30:00', 64500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (10, 9, 14, 'buy', 800, 90000, '2023-06-15 11:00:00', 72000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (3, 16, 4, 'buy', 5000, 27800, '2023-07-10 09:15:00', 139000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (7, 7, 10, 'buy', 1000, 58500, '2023-07-20 10:30:00', 58500, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (5, 12, 7, 'buy', 500, 82000, '2023-08-05 14:00:00', 41000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (8, 11, 12, 'buy', 400, 73500, '2023-08-15 09:00:00', 29400, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 16, 1, 'buy', 2000, 29200, '2023-09-10 10:30:00', 58400, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (2, 9, 3, 'buy', 1200, 93500, '2023-10-05 09:15:00', 112200, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (9, 1, 13, 'buy', 500, 98000, '2023-10-20 11:00:00', 49000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (6, 7, 9, 'buy', 800, 61000, '2023-11-10 09:30:00', 48800, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (10, 11, 14, 'buy', 600, 70000, '2023-11-25 10:00:00', 42000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (7, 9, 10, 'buy', 1500, 102000, '2023-12-05 14:15:00', 153000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (3, 1, 4, 'buy', 1000, 101500, '2023-12-10 09:00:00', 101500, 'completed');
-- Rejected/cancelled order log (Investor 5 attempted to sell HPG without holdings)
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (5, 16, 7, 'sell', 1000, 32000, '2023-12-15 11:30:00', 32000, 'cancelled');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (4, 9, 6, 'buy', 500, 108000, '2023-12-20 10:00:00', 54000, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (1, 14, 2, 'buy', 500, 96500, '2023-12-25 09:30:00', 48250, 'completed');
INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, trade_date, fee, status) VALUES (8, 4, 12, 'buy', 2000, 38000, '2023-12-28 14:00:00', 76000, 'completed');

-- Daily market prices (Nov 2023)
INSERT INTO daily_market_prices (stock_id, price_date, open_price, close_price, high_price, low_price, volume) VALUES
(1,  '2023-11-01',  89200,  90100,  90500,  88800,  2850000),
(1,  '2023-11-02',  90100,  91500,  92000,  89900,  3120000),
(1,  '2023-11-03',  91500,  90800,  92100,  90200,  2680000),
(1,  '2023-11-06',  90800,  92300,  92800,  90500,  3450000),
(1,  '2023-11-07',  92300,  93100,  93500,  91800,  2910000),
(1,  '2023-11-08',  93100,  92600,  93800,  92200,  2540000),
(1,  '2023-11-09',  92600,  94200,  94500,  92300,  3780000),
(1,  '2023-11-10',  94200,  95800,  96100,  93900,  4120000),
(1,  '2023-11-13',  95800,  95200,  96300,  94800,  2890000),
(1,  '2023-11-14',  95200,  96500,  97000,  94900,  3560000),
(1,  '2023-11-15',  96500,  97800,  98200,  96100,  4230000),
(1,  '2023-11-16',  97800,  97100,  98500,  96700,  3100000),
(1,  '2023-11-17',  97100,  98500,  99000,  96800,  3870000),
(1,  '2023-11-20',  98500,  99200,  99800,  98000,  4560000),
(1,  '2023-11-21',  99200,  98800,  99900,  98200,  3240000),

(9,  '2023-11-01',  88500,  89200,  89800,  88100,  1850000),
(9,  '2023-11-02',  89200,  90800,  91200,  89000,  2120000),
(9,  '2023-11-03',  90800,  90200,  91500,  89800,  1780000),
(9,  '2023-11-06',  90200,  92500,  93000,  90000,  2450000),
(9,  '2023-11-07',  92500,  93800,  94200,  92100,  2210000),
(9,  '2023-11-08',  93800,  93200,  94500,  92800,  1940000),
(9,  '2023-11-09',  93200,  95500,  95900,  92900,  2780000),
(9,  '2023-11-10',  95500,  97200,  97600,  95200,  3120000),
(9,  '2023-11-13',  97200,  96800,  97900,  96400,  1990000),
(9,  '2023-11-14',  96800,  98500,  99000,  96500,  2560000),
(9,  '2023-11-15',  98500,  99800, 100200,  98100,  3230000),
(9,  '2023-11-16',  99800,  99200, 100500,  98800,  2100000),
(9,  '2023-11-17',  99200, 100800, 101200,  98900,  2870000),
(9,  '2023-11-20', 100800, 101500, 102000, 100400,  3450000),
(9,  '2023-11-21', 101500, 101000, 102200, 100800,  2240000),

(16, '2023-11-01',  27200,  27800,  28100,  26900,  8500000),
(16, '2023-11-02',  27800,  28500,  28800,  27500,  9200000),
(16, '2023-11-03',  28500,  28100,  28900,  27800,  7800000),
(16, '2023-11-06',  28100,  29200,  29500,  27900, 10500000),
(16, '2023-11-07',  29200,  29800,  30100,  28900,  9800000),
(16, '2023-11-08',  29800,  29400,  30200,  29100,  8200000),
(16, '2023-11-09',  29400,  30500,  30800,  29200, 11200000),
(16, '2023-11-10',  30500,  31200,  31500,  30200, 12800000),
(16, '2023-11-13',  31200,  30800,  31600,  30500,  9600000),
(16, '2023-11-14',  30800,  31800,  32100,  30500, 10900000),
(16, '2023-11-15',  31800,  32500,  32800,  31500, 13500000),
(16, '2023-11-16',  32500,  32100,  32900,  31800, 10200000),
(16, '2023-11-17',  32100,  32800,  33100,  31900, 11500000),
(16, '2023-11-20',  32800,  33200,  33500,  32500, 12100000),
(16, '2023-11-21',  33200,  32900,  33600,  32600,  9800000),

(11, '2023-11-01',  70200,  70800,  71200,  69800,   980000),
(11, '2023-11-02',  70800,  71500,  71800,  70500,  1120000),
(11, '2023-11-03',  71500,  71000,  71900,  70700,   890000),
(11, '2023-11-06',  71000,  72100,  72500,  70800,  1250000),
(11, '2023-11-07',  72100,  72800,  73100,  71800,  1080000),
(11, '2023-11-08',  72800,  72300,  73200,  72000,   920000),
(11, '2023-11-09',  72300,  73500,  73800,  72100,  1380000),
(11, '2023-11-10',  73500,  74200,  74500,  73200,  1560000),
(11, '2023-11-13',  74200,  73800,  74600,  73500,  1050000),
(11, '2023-11-14',  73800,  74800,  75100,  73500,  1290000),
(11, '2023-11-15',  74800,  75500,  75800,  74500,  1640000),
(11, '2023-11-16',  75500,  75000,  75900,  74700,  1120000),
(11, '2023-11-17',  75000,  75800,  76100,  74800,  1350000),
(11, '2023-11-20',  75800,  76200,  76500,  75500,  1480000),
(11, '2023-11-21',  76200,  75900,  76600,  75600,  1090000),

(4,  '2023-11-20',  34000,  34500,  34800,  33800,  4200000),
(4,  '2023-11-21',  34500,  34900,  35200,  34300,  4500000),
(5,  '2023-11-20',  23100,  23400,  23600,  22900,  6100000),
(5,  '2023-11-21',  23400,  23700,  23900,  23200,  6400000),
(6,  '2023-11-20',  62500,  61800,  62800,  61500,  1950000),
(6,  '2023-11-21',  61800,  61200,  62100,  61000,  2100000),
(7,  '2023-11-20',  56800,  57200,  57600,  56500,  2300000),
(7,  '2023-11-21',  57200,  57600,  58000,  57000,  2450000),
(12, '2023-11-20',  79500,  80200,  80600,  79100,  1400000),
(12, '2023-11-21',  80200,  80800,  81200,  79900,  1520000),
(14, '2023-11-20',  96800,  97400,  97900,  96500,   890000),
(14, '2023-11-21',  97400,  97900,  98400,  97100,   940000),
(18, '2023-11-20', 102000, 103000, 103500, 101800,   320000),
(18, '2023-11-21', 103000, 103800, 104200, 102600,   350000);

-- Dividend declarations (2023)
INSERT INTO dividends (stock_id, declared_date, payment_date, amount_per_share, dividend_type) VALUES
(1,  '2023-03-15', '2023-04-10', 1800, 'cash'),
(1,  '2023-09-20', '2023-10-15', 1800, 'cash'),
(9,  '2023-04-05', '2023-05-01', 2000, 'cash'),
(9,  '2023-10-10', '2023-11-05', 2000, 'cash'),
(11, '2023-02-20', '2023-03-15', 1000, 'cash'),
(11, '2023-08-15', '2023-09-10', 1000, 'cash'),
(16, '2023-05-10', '2023-06-05',  200, 'stock'),
(14, '2023-03-01', '2023-03-25', 3500, 'cash'),
(14, '2023-09-01', '2023-09-25', 3500, 'cash'),
(6,  '2023-06-01', '2023-07-01',  100, 'stock'),
(4,  '2023-04-15', '2023-05-10', 1500, 'cash'),
(7,  '2023-07-20', '2023-08-15', 2000, 'cash'),
(12, '2023-05-25', '2023-06-20', 1200, 'cash'),
(18, '2023-03-10', '2023-04-05', 5000, 'cash'),
(18, '2023-09-10', '2023-10-05', 3000, 'cash');

--------------------------------------------------------------------------
--SECTION 4: View

-- 1. Daily stock performance ranking (Latest trading day vs. Previous trading day)
CREATE OR REPLACE VIEW vw_top_performing_stocks AS
WITH ranked_prices AS (
    SELECT
        stock_id,
        price_date,
        close_price,
        volume,
        ROW_NUMBER() OVER (PARTITION BY stock_id ORDER BY price_date DESC) AS rn
    FROM daily_market_prices
),
latest_day AS (
    SELECT * FROM ranked_prices WHERE rn = 1
),
prev_day AS (
    SELECT * FROM ranked_prices WHERE rn = 2
)
SELECT
    s.stock_symbol,
    s.company_name,
    sec.sector_name,
    e.exchange_name,
    t.price_date AS latest_date,
    t.close_price,
    y.close_price AS prev_close,
    ROUND(t.close_price - y.close_price, 0) AS price_change,
    ROUND((t.close_price - y.close_price) / NULLIF(y.close_price, 0) * 100, 2) AS pct_change,
    t.volume,
    RANK() OVER (ORDER BY (t.close_price - y.close_price) / NULLIF(y.close_price, 0) DESC) AS performance_rank
FROM latest_day t
JOIN prev_day y   ON y.stock_id = t.stock_id
JOIN stocks s     ON s.stock_id = t.stock_id
JOIN sectors sec  ON sec.sector_id = s.sector_id
JOIN exchanges e  ON e.exchange_id = s.exchange_id
WHERE s.status = 'active';


-- 2. Investor portfolio holdings and unrealized PnL valuation
CREATE OR REPLACE VIEW vw_investor_portfolio AS
WITH latest_prices AS (
    SELECT DISTINCT ON (stock_id)
        stock_id,
        price_date,
        close_price
    FROM daily_market_prices
    ORDER BY stock_id, price_date DESC
),
position_valuation AS (
    SELECT
        ph.investor_id,
        ph.stock_id,
        ph.quantity,
        ph.average_cost,
        lp.price_date AS valuation_date,
        COALESCE(lp.close_price, ph.average_cost) AS close_price,
        ph.quantity * ph.average_cost AS cost_basis,
        ph.quantity * COALESCE(lp.close_price, ph.average_cost) AS current_value,
        ph.quantity * (COALESCE(lp.close_price, ph.average_cost) - ph.average_cost) AS unrealized_pnl
    FROM portfolio_holdings ph
    LEFT JOIN latest_prices lp ON lp.stock_id = ph.stock_id
),
investor_totals AS (
    SELECT
        investor_id,
        SUM(current_value) AS total_portfolio_value
    FROM position_valuation
    GROUP BY investor_id
)
SELECT
    i.investor_id,
    i.full_name AS investor_name,
    s.stock_symbol,
    s.company_name,
    sec.sector_name,
    pv.valuation_date,
    pv.quantity AS shares_held,
    ROUND(pv.average_cost, 2) AS avg_cost,
    ROUND(pv.close_price, 2) AS current_price,
    ROUND(pv.cost_basis, 0) AS cost_basis,
    ROUND(pv.current_value, 0) AS market_value,
    ROUND(pv.unrealized_pnl, 0) AS unrealized_pnl,
    ROUND((pv.close_price - pv.average_cost) / NULLIF(pv.average_cost, 0) * 100, 2) AS roi_percent,
    ROUND(pv.current_value / NULLIF(it.total_portfolio_value, 0) * 100, 2) AS weight_pct,
    CASE
        WHEN pv.unrealized_pnl > 0 THEN 'Profit'
        WHEN pv.unrealized_pnl < 0 THEN 'Loss'
        ELSE 'Breakeven'
    END AS position_status
FROM position_valuation pv
JOIN investor_totals it ON it.investor_id = pv.investor_id
JOIN investors i        ON i.investor_id = pv.investor_id
JOIN stocks s           ON s.stock_id = pv.stock_id
JOIN sectors sec        ON sec.sector_id = s.sector_id
ORDER BY i.investor_id, pv.current_value DESC;


-- 3. Monthly portfolio summary report
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_portfolio_report;

CREATE MATERIALIZED VIEW mv_monthly_portfolio_report AS
WITH latest_prices AS (
    SELECT DISTINCT ON (stock_id)
        stock_id,
        price_date,
        close_price
    FROM daily_market_prices
    ORDER BY stock_id, price_date DESC
)
SELECT
    DATE_TRUNC('month', MAX(lp.price_date))::DATE AS report_month,
    MAX(lp.price_date) AS valuation_date,
    i.investor_id,
    i.full_name,
    COUNT(DISTINCT ph.stock_id) AS num_positions,
    ROUND(SUM(ph.quantity * ph.average_cost), 0) AS total_cost,
    ROUND(SUM(ph.quantity * COALESCE(lp.close_price, ph.average_cost)), 0) AS market_value,
    ROUND(SUM(ph.quantity * (COALESCE(lp.close_price, ph.average_cost) - ph.average_cost)), 0) AS unrealized_pnl,
    ROUND(
        SUM(ph.quantity * (COALESCE(lp.close_price, ph.average_cost) - ph.average_cost))
        / NULLIF(SUM(ph.quantity * ph.average_cost), 0) * 100,
        2
    ) AS roi_pct,
    CURRENT_TIMESTAMP AS generated_at
FROM investors i
JOIN portfolio_holdings ph ON ph.investor_id = i.investor_id
LEFT JOIN latest_prices lp ON lp.stock_id = ph.stock_id
GROUP BY i.investor_id, i.full_name
ORDER BY market_value DESC
WITH DATA;

----------------------------------------------------------------------
--SECTION 5: Analysis

-- Q1: Stock return and daily volatility summary (Nov 2023)
WITH stock_window AS (
    SELECT
        dmp.stock_id,
        dmp.price_date,
        dmp.close_price,
        dmp.volume,
        FIRST_VALUE(dmp.close_price) OVER (
            PARTITION BY dmp.stock_id ORDER BY dmp.price_date ASC
        ) AS first_close,
        LAST_VALUE(dmp.close_price) OVER (
            PARTITION BY dmp.stock_id ORDER BY dmp.price_date ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS last_close,
        LAG(dmp.close_price) OVER (
            PARTITION BY dmp.stock_id ORDER BY dmp.price_date ASC
        ) AS prev_day_close
    FROM daily_market_prices dmp
),
daily_returns AS (
    SELECT
        stock_id,
        price_date,
        close_price,
        volume,
        first_close,
        last_close,
        (close_price - prev_day_close) / NULLIF(prev_day_close, 0) * 100 AS daily_ret_pct
    FROM stock_window
)
SELECT
    s.stock_symbol,
    sec.sector_name,
    COUNT(*) AS trading_days,
    MIN(dr.price_date) AS start_date,
    MAX(dr.price_date) AS end_date,
    MAX(dr.first_close) AS start_close,
    MAX(dr.last_close) AS end_close,
    ROUND(MAX(dr.last_close) - MAX(dr.first_close), 0) AS price_change,
    ROUND((MAX(dr.last_close) - MAX(dr.first_close)) / NULLIF(MAX(dr.first_close), 0) * 100, 2) AS period_return_pct,
    ROUND(STDDEV_SAMP(dr.daily_ret_pct), 2) AS volatility_pct,
    ROUND(AVG(dr.volume), 0) AS avg_daily_volume
FROM daily_returns dr
JOIN stocks s    ON s.stock_id = dr.stock_id
JOIN sectors sec ON sec.sector_id = s.sector_id
GROUP BY s.stock_id, s.stock_symbol, sec.sector_name
HAVING COUNT(*) >= 5
ORDER BY period_return_pct DESC;


-- Q2: Investor net worth, cash vs. equity allocation, and total ROI
WITH cash_summary AS (
    SELECT
        investor_id,
        SUM(CASE WHEN account_type = 'cash'   THEN balance ELSE 0 END) AS cash_balance,
        SUM(CASE WHEN account_type = 'margin' THEN balance ELSE 0 END) AS margin_balance,
        SUM(balance) AS total_cash_balance
    FROM accounts
    GROUP BY investor_id
),
equity_summary AS (
    SELECT
        investor_id,
        COUNT(stock_symbol) AS held_tickers,
        SUM(cost_basis) AS total_equity_cost,
        SUM(market_value) AS total_equity_value,
        SUM(unrealized_pnl) AS total_unrealized_pnl
    FROM vw_investor_portfolio
    GROUP BY investor_id
)
SELECT
    i.investor_id,
    i.full_name,
    COALESCE(es.held_tickers, 0) AS held_tickers,
    ROUND(COALESCE(cs.total_cash_balance, 0), 0) AS total_cash_vnd,
    ROUND(COALESCE(es.total_equity_cost, 0), 0) AS equity_cost_vnd,
    ROUND(COALESCE(es.total_equity_value, 0), 0) AS equity_value_vnd,
    ROUND(COALESCE(cs.total_cash_balance, 0) + COALESCE(es.total_equity_value, 0), 0) AS net_worth_vnd,
    ROUND(COALESCE(es.total_unrealized_pnl, 0), 0) AS unrealized_pnl_vnd,
    ROUND(
        COALESCE(es.total_unrealized_pnl, 0) / NULLIF(es.total_equity_cost, 0) * 100,
        2
    ) AS equity_roi_pct,
    ROUND(
        COALESCE(es.total_equity_value, 0)
        / NULLIF(COALESCE(cs.total_cash_balance, 0) + COALESCE(es.total_equity_value, 0), 0) * 100,
        2
    ) AS equity_weight_pct
FROM investors i
LEFT JOIN cash_summary cs   ON cs.investor_id = i.investor_id
LEFT JOIN equity_summary es ON es.investor_id = i.investor_id
ORDER BY net_worth_vnd DESC;


-- Q3: Sector allocation and exposure per investor
WITH sector_exposure AS (
    SELECT
        investor_id,
        investor_name,
        sector_name,
        COUNT(stock_symbol) AS tickers_in_sector,
        SUM(market_value) AS sector_market_value,
        SUM(unrealized_pnl) AS sector_unrealized_pnl
    FROM vw_investor_portfolio
    GROUP BY investor_id, investor_name, sector_name
)
SELECT
    investor_id,
    investor_name,
    sector_name,
    tickers_in_sector,
    sector_market_value,
    sector_unrealized_pnl,
    ROUND(
        sector_market_value
        / NULLIF(SUM(sector_market_value) OVER (PARTITION BY investor_id), 0) * 100,
        2
    ) AS sector_weight_pct,
    RANK() OVER (PARTITION BY investor_id ORDER BY sector_market_value DESC) AS sector_rank
FROM sector_exposure
ORDER BY investor_id, sector_rank;


-- Q4: Portfolio concentration risk using Herfindahl-Hirschman Index (HHI)
WITH position_weights AS (
    SELECT
        investor_id,
        investor_name,
        stock_symbol,
        market_value,
        weight_pct,
        ROW_NUMBER() OVER (PARTITION BY investor_id ORDER BY weight_pct DESC) AS pos_rank
    FROM vw_investor_portfolio
)
SELECT
    investor_id,
    investor_name,
    COUNT(*) AS num_holdings,
    SUM(market_value) AS total_equity_value,
    MAX(CASE WHEN pos_rank = 1 THEN stock_symbol END) AS top_holding,
    MAX(CASE WHEN pos_rank = 1 THEN weight_pct END) AS top_holding_weight_pct,
    ROUND(SUM(POWER(weight_pct, 2)), 0) AS hhi_score,
    CASE
        WHEN MAX(weight_pct) >= 50 OR SUM(POWER(weight_pct, 2)) >= 4000 THEN 'High Concentration'
        WHEN MAX(weight_pct) >= 35 OR SUM(POWER(weight_pct, 2)) >= 2500 THEN 'Moderate Concentration'
        ELSE 'Diversified'
    END AS risk_level
FROM position_weights
GROUP BY investor_id, investor_name
ORDER BY hhi_score DESC;


-- Q5: Holding rank and cumulative weight within each portfolio
SELECT
    investor_id,
    investor_name,
    stock_symbol,
    sector_name,
    market_value,
    roi_percent,
    weight_pct,
    DENSE_RANK() OVER (PARTITION BY investor_id ORDER BY market_value DESC) AS value_rank,
    ROUND(
        SUM(weight_pct) OVER (
            PARTITION BY investor_id
            ORDER BY market_value DESC, stock_symbol ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),
        2
    ) AS cumulative_weight_pct
FROM vw_investor_portfolio
ORDER BY investor_id, value_rank;


-- Q6: Realized vs. Unrealized PnL reconciliation (using chronological weighted-average cost)
WITH RECURSIVE trade_history AS (
    SELECT
        t.trade_id,
        t.investor_id,
        t.stock_id,
        t.trade_type,
        t.quantity,
        t.price_per_share,
        t.fee,
        t.trade_date,
        ROW_NUMBER() OVER (
            PARTITION BY t.investor_id, t.stock_id
            ORDER BY t.trade_date ASC, t.trade_id ASC
        ) AS seq_num
    FROM trades t
    WHERE t.status = 'completed'
),
cost_calc AS (
    SELECT
        th.trade_id,
        th.investor_id,
        th.stock_id,
        th.trade_type,
        th.quantity,
        th.price_per_share,
        th.fee,
        th.trade_date,
        th.seq_num,
        th.quantity AS running_qty,
        ROUND(th.price_per_share, 2) AS avg_cost_before,
        ROUND(th.price_per_share, 2) AS avg_cost_after
    FROM trade_history th
    WHERE th.seq_num = 1

    UNION ALL

    SELECT
        th.trade_id,
        th.investor_id,
        th.stock_id,
        th.trade_type,
        th.quantity,
        th.price_per_share,
        th.fee,
        th.trade_date,
        th.seq_num,
        CASE
            WHEN th.trade_type = 'buy'  THEN cc.running_qty + th.quantity
            WHEN th.trade_type = 'sell' THEN cc.running_qty - th.quantity
        END AS running_qty,
        cc.avg_cost_after AS avg_cost_before,
        CASE
            WHEN th.trade_type = 'buy' THEN
                ROUND(
                    (cc.running_qty * cc.avg_cost_after + th.quantity * th.price_per_share)
                    / NULLIF(cc.running_qty + th.quantity, 0),
                    2
                )
            WHEN th.trade_type = 'sell' THEN
                CASE
                    WHEN cc.running_qty - th.quantity = 0 THEN 0::NUMERIC(12, 2)
                    ELSE cc.avg_cost_after
                END
        END AS avg_cost_after
    FROM trade_history th
    JOIN cost_calc cc
      ON cc.investor_id = th.investor_id
     AND cc.stock_id = th.stock_id
     AND th.seq_num = cc.seq_num + 1
),
sell_pnl AS (
    SELECT
        cc.investor_id,
        cc.stock_id,
        (cc.quantity * cc.price_per_share - cc.fee) - (cc.quantity * cc.avg_cost_before) AS realized_net_pnl
    FROM cost_calc cc
    WHERE cc.trade_type = 'sell'
)
SELECT
    i.investor_id,
    i.full_name,
    COUNT(sp.stock_id) AS sell_trades_count,
    COALESCE(ROUND(SUM(sp.realized_net_pnl), 0), 0) AS realized_pnl_vnd,
    COALESCE(ROUND(MAX(mv.unrealized_pnl), 0), 0) AS unrealized_pnl_vnd,
    COALESCE(ROUND(SUM(sp.realized_net_pnl), 0), 0)
        + COALESCE(ROUND(MAX(mv.unrealized_pnl), 0), 0) AS total_pnl_vnd
FROM investors i
LEFT JOIN sell_pnl sp                    ON sp.investor_id = i.investor_id
LEFT JOIN mv_monthly_portfolio_report mv ON mv.investor_id = i.investor_id
GROUP BY i.investor_id, i.full_name
ORDER BY total_pnl_vnd DESC;


-- Q7: Brokerage fee revenue and fee calculation check
WITH trade_fees AS (
    SELECT
        t.trade_id,
        t.investor_id,
        i.full_name,
        t.quantity * t.price_per_share AS trade_value,
        t.fee AS charged_fee,
        fn_calculate_trading_fee(t.trade_type, t.quantity, t.price_per_share) AS standard_fee
    FROM trades t
    JOIN investors i ON i.investor_id = t.investor_id
    WHERE t.status = 'completed'
)
SELECT
    investor_id,
    full_name,
    COUNT(trade_id) AS completed_trades,
    ROUND(SUM(trade_value), 0) AS total_volume_vnd,
    ROUND(SUM(charged_fee), 0) AS charged_fees_vnd,
    ROUND(SUM(standard_fee), 0) AS standard_fees_vnd,
    ROUND(SUM(standard_fee - charged_fee), 0) AS fee_diff_vnd,
    ROUND(SUM(charged_fee) / NULLIF(SUM(trade_value), 0) * 100, 4) AS effective_fee_rate_pct
FROM trade_fees
GROUP BY investor_id, full_name
ORDER BY charged_fees_vnd DESC;


-- Q8: Monthly trading volume and net cash flow (2023)
WITH monthly_stats AS (
    SELECT
        DATE_TRUNC('month', trade_date)::DATE AS trade_month,
        COUNT(*) AS trade_count,
        COUNT(DISTINCT investor_id) AS active_investors,
        SUM(CASE WHEN trade_type = 'buy'  THEN quantity * price_per_share ELSE 0 END) AS buy_volume_vnd,
        SUM(CASE WHEN trade_type = 'sell' THEN quantity * price_per_share ELSE 0 END) AS sell_volume_vnd,
        SUM(quantity * price_per_share) AS total_volume_vnd
    FROM trades
    WHERE status = 'completed'
    GROUP BY DATE_TRUNC('month', trade_date)::DATE
)
SELECT
    trade_month,
    trade_count,
    active_investors,
    ROUND(buy_volume_vnd, 0) AS buy_volume_vnd,
    ROUND(sell_volume_vnd, 0) AS sell_volume_vnd,
    ROUND(buy_volume_vnd - sell_volume_vnd, 0) AS net_buy_flow_vnd,
    ROUND(total_volume_vnd, 0) AS monthly_turnover_vnd,
    ROUND(
        SUM(total_volume_vnd) OVER (ORDER BY trade_month ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
        0
    ) AS ytd_turnover_vnd
FROM monthly_stats
ORDER BY trade_month ASC;


-- Q9: Dividend eligibility check (Declared-date holdings vs. Current holdings)
WITH actual_dividends AS (
    SELECT
        i.investor_id,
        i.full_name,
        COALESCE(SUM(f.cash_dividend_vnd), 0) AS actual_dividend_vnd
    FROM investors i
    LEFT JOIN LATERAL fn_calculate_dividend_income(i.investor_id, 2023) f ON TRUE
    GROUP BY i.investor_id, i.full_name
),
snapshot_dividends AS (
    SELECT
        ph.investor_id,
        SUM(ROUND(ph.quantity * d.amount_per_share, 0)) AS snapshot_dividend_vnd
    FROM portfolio_holdings ph
    JOIN dividends d ON d.stock_id = ph.stock_id
    WHERE EXTRACT(YEAR FROM d.payment_date) = 2023
      AND d.dividend_type = 'cash'
    GROUP BY ph.investor_id
)
SELECT
    ad.investor_id,
    ad.full_name,
    ad.actual_dividend_vnd,
    COALESCE(sd.snapshot_dividend_vnd, 0) AS snapshot_dividend_vnd,
    COALESCE(sd.snapshot_dividend_vnd, 0) - ad.actual_dividend_vnd AS dividend_diff_vnd
FROM actual_dividends ad
LEFT JOIN snapshot_dividends sd ON sd.investor_id = ad.investor_id
ORDER BY dividend_diff_vnd DESC;


-- Q10: Data quality and operational anomaly check
WITH latest_market_date AS (
    SELECT stock_id, MAX(price_date) AS max_price_date
    FROM daily_market_prices
    GROUP BY stock_id
)
SELECT
    '1. Cancelled / Pending Trade' AS anomaly_type,
    'trade_id=' || t.trade_id || ' (investor_id=' || t.investor_id || ', stock=' || s.stock_symbol || ')' AS record_ref,
    t.trade_date::DATE AS event_date,
    'Order to ' || t.trade_type || ' ' || t.quantity || ' shares has status: ' || t.status AS details
FROM trades t
JOIN stocks s ON s.stock_id = t.stock_id
WHERE t.status != 'completed'

UNION ALL

SELECT
    '2. Trade After Latest Price Date' AS anomaly_type,
    'trade_id=' || t.trade_id || ' (investor_id=' || t.investor_id || ', stock=' || s.stock_symbol || ')' AS record_ref,
    t.trade_date::DATE AS event_date,
    'Trade date (' || t.trade_date::DATE || ') is newer than latest market price (' || COALESCE(lmd.max_price_date::TEXT, 'N/A') || ')' AS details
FROM trades t
JOIN stocks s ON s.stock_id = t.stock_id
LEFT JOIN latest_market_date lmd ON lmd.stock_id = t.stock_id
WHERE t.status = 'completed'
  AND (lmd.max_price_date IS NULL OR t.trade_date::DATE > lmd.max_price_date)

UNION ALL

SELECT
    '3. Active Stock Missing Price Data' AS anomaly_type,
    'stock_id=' || s.stock_id || ' (' || s.stock_symbol || ')' AS record_ref,
    s.listing_date AS event_date,
    'Listed on ' || e.exchange_name || ' but has no records in daily_market_prices' AS details
FROM stocks s
JOIN exchanges e ON e.exchange_id = s.exchange_id
LEFT JOIN latest_market_date lmd ON lmd.stock_id = s.stock_id
WHERE lmd.stock_id IS NULL
ORDER BY anomaly_type, event_date;



-----------------------------------------------------------------------------------------
--SECTION 6: Test
-- TEST 1: Reconcile portfolio_holdings against trade history
-- Expected: 0 rows returned (quantities and average costs match 100%)
WITH RECURSIVE trade_history AS (
    SELECT
        t.trade_id,
        t.investor_id,
        t.stock_id,
        t.trade_type,
        t.quantity,
        t.price_per_share,
        ROW_NUMBER() OVER (
            PARTITION BY t.investor_id, t.stock_id
            ORDER BY t.trade_date ASC, t.trade_id ASC
        ) AS seq_num,
        COUNT(*) OVER (
            PARTITION BY t.investor_id, t.stock_id
        ) AS total_trades
    FROM trades t
    WHERE t.status = 'completed'
),
calc_holdings AS (
    SELECT
        th.investor_id,
        th.stock_id,
        th.seq_num,
        th.total_trades,
        th.quantity AS running_qty,
        ROUND(th.price_per_share, 2) AS running_avg_cost
    FROM trade_history th
    WHERE th.seq_num = 1

    UNION ALL

    SELECT
        th.investor_id,
        th.stock_id,
        th.seq_num,
        th.total_trades,
        CASE
            WHEN th.trade_type = 'buy'  THEN ch.running_qty + th.quantity
            WHEN th.trade_type = 'sell' THEN ch.running_qty - th.quantity
        END AS running_qty,
        CASE
            WHEN th.trade_type = 'buy' THEN
                ROUND(
                    (ch.running_qty * ch.running_avg_cost + th.quantity * th.price_per_share)
                    / NULLIF(ch.running_qty + th.quantity, 0),
                    2
                )
            WHEN th.trade_type = 'sell' THEN
                CASE
                    WHEN ch.running_qty - th.quantity = 0 THEN 0::NUMERIC(12, 2)
                    ELSE ch.running_avg_cost
                END
        END AS running_avg_cost
    FROM trade_history th
    JOIN calc_holdings ch
      ON ch.investor_id = th.investor_id
     AND ch.stock_id = th.stock_id
     AND th.seq_num = ch.seq_num + 1
),
expected_holdings AS (
    SELECT
        investor_id,
        stock_id,
        running_qty AS expected_qty,
        running_avg_cost AS expected_avg_cost
    FROM calc_holdings
    WHERE seq_num = total_trades
      AND running_qty > 0
)
SELECT
    COALESCE(ph.investor_id, eh.investor_id) AS investor_id,
    COALESCE(ph.stock_id, eh.stock_id) AS stock_id,
    ph.quantity AS actual_qty,
    eh.expected_qty,
    ph.average_cost AS actual_avg_cost,
    eh.expected_avg_cost
FROM portfolio_holdings ph
FULL OUTER JOIN expected_holdings eh
  ON eh.investor_id = ph.investor_id AND eh.stock_id = ph.stock_id
WHERE ph.quantity IS DISTINCT FROM eh.expected_qty
   OR ph.average_cost IS DISTINCT FROM eh.expected_avg_cost;


-- TEST 2: Check if any holdings are missing from vw_investor_portfolio
-- Expected: missing_rows = 0
SELECT
    (SELECT COUNT(*) FROM portfolio_holdings) AS holding_table_count,
    (SELECT COUNT(*) FROM vw_investor_portfolio) AS view_row_count,
    (SELECT COUNT(*) FROM portfolio_holdings) - (SELECT COUNT(*) FROM vw_investor_portfolio) AS missing_rows;


-- TEST 3: Verify portfolio weights sum to ~100% per investor
SELECT
    investor_id,
    investor_name,
    COUNT(*) AS positions,
    SUM(weight_pct) AS total_weight_pct
FROM vw_investor_portfolio
GROUP BY investor_id, investor_name
ORDER BY investor_id;


-- TEST 4: Pending order lifecycle test (rolled back after check)
BEGIN;

    -- 4A: Pending sell order exceeding current holdings (should be allowed while pending)
    INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, status)
    VALUES (2, 4, 3, 'sell', 5000, 35000, 'pending');

    -- 4B: Pending buy order (balance and holdings should remain unchanged)
    INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, status)
    VALUES (10, 1, 14, 'buy', 500, 99000, 'pending');

    SELECT 'WHILE PENDING' AS stage,
           (SELECT balance FROM accounts WHERE account_id = 14) AS acc_14_balance,
           (SELECT COALESCE(quantity, 0) FROM portfolio_holdings WHERE investor_id = 10 AND stock_id = 1) AS inv_10_vcb_qty;

    -- 4C: Update status to completed (triggers should now deduct cash and add shares)
    UPDATE trades
    SET status = 'completed'
    WHERE investor_id = 10 AND stock_id = 1 AND status = 'pending';

    SELECT 'AFTER COMPLETED' AS stage,
           (SELECT balance FROM accounts WHERE account_id = 14) AS acc_14_balance,
           (SELECT COALESCE(quantity, 0) FROM portfolio_holdings WHERE investor_id = 10 AND stock_id = 1) AS inv_10_vcb_qty;

ROLLBACK;


-- TEST 5: Negative test cases for business rule triggers
DO $test$
DECLARE
    v_test1_pass BOOLEAN := FALSE;
    v_test2_pass BOOLEAN := FALSE;
    v_test3_pass BOOLEAN := FALSE;
BEGIN
    -- 5A: Short selling check
    BEGIN
        INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, status)
        VALUES (2, 4, 3, 'sell', 2000, 38500, 'completed');
    EXCEPTION WHEN OTHERS THEN
        v_test1_pass := TRUE;
        RAISE NOTICE 'TEST 5A PASSED (Oversell Blocked): %', SQLERRM;
    END;

    IF NOT v_test1_pass THEN
        RAISE EXCEPTION 'TEST 5A FAILED: Oversell was not blocked.';
    END IF;

    -- 5B: Cross-investor account check
    BEGIN
        INSERT INTO trades (investor_id, stock_id, account_id, trade_type, quantity, price_per_share, status)
        VALUES (1, 1, 10, 'buy', 100, 95000, 'completed');
    EXCEPTION WHEN OTHERS THEN
        v_test2_pass := TRUE;
        RAISE NOTICE 'TEST 5B PASSED (Account Mismatch Blocked): %', SQLERRM;
    END;

    IF NOT v_test2_pass THEN
        RAISE EXCEPTION 'TEST 5B FAILED: Cross-investor trade was not blocked.';
    END IF;

    -- 5C: Completed/cancelled trade immutability check
    BEGIN
        UPDATE trades
        SET status = 'completed'
        WHERE investor_id = 5 AND stock_id = 16 AND status = 'cancelled';
    EXCEPTION WHEN OTHERS THEN
        v_test3_pass := TRUE;
        RAISE NOTICE 'TEST 5C PASSED (Status Modification Blocked): %', SQLERRM;
    END;

    IF NOT v_test3_pass THEN
        RAISE EXCEPTION 'TEST 5C FAILED: Cancelled trade was modified.';
    END IF;
END;
$test$;


-- TEST 6: Transaction atomicity and rollback check on insufficient balance
-- Account 12 has 95,000,000 VND after seed trades; attempting to transfer 200,000,000 VND to Account 2.
DO $acid$
DECLARE
    v_acc2_before     NUMERIC;
    v_acc12_before    NUMERIC;
    v_acc2_after      NUMERIC;
    v_acc12_after     NUMERIC;
    v_rollback_caught BOOLEAN := FALSE;
BEGIN
    SELECT balance INTO v_acc2_before  FROM accounts WHERE account_id = 2;
    SELECT balance INTO v_acc12_before FROM accounts WHERE account_id = 12;

    BEGIN
        UPDATE accounts SET balance = balance + 200000000 WHERE account_id = 2;
        UPDATE accounts SET balance = balance - 200000000 WHERE account_id = 12;

    EXCEPTION WHEN check_violation THEN
        v_rollback_caught := TRUE;
        RAISE NOTICE 'TEST 6 PASSED: Check violation caught (%). Transaction rolled back.', SQLERRM;
        INSERT INTO audit_log (action_type, table_name, description, status)
        VALUES ('TRANSFER', 'accounts', 'Failed transfer of 200M VND from account 12 to account 2', 'ROLLED_BACK');
    END;

    IF NOT v_rollback_caught THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Negative balance was not blocked.';
    END IF;

    SELECT balance INTO v_acc2_after  FROM accounts WHERE account_id = 2;
    SELECT balance INTO v_acc12_after FROM accounts WHERE account_id = 12;

    IF v_acc2_after != v_acc2_before OR v_acc12_after != v_acc12_before THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Balances changed after rollback.';
    END IF;
END;
$acid$;

SELECT account_id, investor_id, account_type, balance
FROM accounts
WHERE account_id IN (2, 12)
ORDER BY account_id;
