-- backup-vault demo: least-privilege user for database backups.
-- The backup user can read data but cannot write, drop or alter anything.
CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY 'backupdemo-pass';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, PROCESS ON *.* TO 'backup'@'%';
FLUSH PRIVILEGES;
