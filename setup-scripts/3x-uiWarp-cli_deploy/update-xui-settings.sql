-- update-xui-settings.sql
-- Params should be passed through .param set before running transaction
-- Usage: sqlite3 x-ui.db < update-xui-settings.sql

BEGIN TRANSACTION;

UPDATE settings SET value = ''           WHERE key = 'webListen';
UPDATE settings SET value = ''           WHERE key = 'webDomain';
UPDATE settings SET value = :webPort     WHERE key = 'webPort';
UPDATE settings SET value = :certFile    WHERE key = 'webCertFile';
UPDATE settings SET value = :keyFile     WHERE key = 'webKeyFile';

COMMIT;