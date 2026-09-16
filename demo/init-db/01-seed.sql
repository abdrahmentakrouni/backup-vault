-- backup-vault demo seed: a small "company" database for the disaster drill.
CREATE TABLE customers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(120) NOT NULL,
    plan VARCHAR(40) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO customers (name, plan) VALUES
    ('ACME Industries', 'enterprise'),
    ('Sahara Logistics', 'business'),
    ('Medina Retail Group', 'business'),
    ('Oasis Cloud Ltd', 'startup');
