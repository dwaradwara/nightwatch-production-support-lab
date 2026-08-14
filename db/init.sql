CREATE TABLE IF NOT EXISTS tickets (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL
);

INSERT INTO tickets (title, severity, status) VALUES
('Customer API returning 502', 'SEV2', 'Resolved'),
('Database latency investigation', 'SEV3', 'Investigating'),
('Worker queue processing delay', 'SEV3', 'Open');
