-- Create a sample users table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    power INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert some sample data
INSERT INTO users (name, email, power) VALUES
    ('Goku', 'goku@capsule.corp', 9001),
    ('Vegeta', 'vegeta@capsule.corp', 8500),
    ('Piccolo', 'piccolo@namek.org', 3500),
    ('Gohan', 'gohan@orange.edu', 7000),
    ('Krillin', 'krillin@kame.house', 1500);
