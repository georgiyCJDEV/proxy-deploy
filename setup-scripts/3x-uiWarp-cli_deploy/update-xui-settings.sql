-- update-xui-settings.sql
-- Params should be passed through .param set before running transaction
-- Usage: sqlite3 x-ui.db < update-xui-settings.sql

UPDATE settings
SET value = CASE
                WHEN key = 'webListen' THEN ''
                WHEN key = 'webDomain' THEN ''
                WHEN key = 'webPort' THEN :webPort
                WHEN key = 'webCertFile' THEN :certFile
                WHEN key = 'webKeyFile' THEN :keyFile
    END
WHERE key IN ('webListen', 'webDomain', 'webPort', 'webCertFile', 'webKeyFile');
