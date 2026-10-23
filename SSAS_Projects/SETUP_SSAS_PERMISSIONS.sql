/* =====================================================================
   Файл: SETUP_SSAS_PERMISSIONS.sql
   Опис: Доступ служби Analysis Services до сховища PolyclinicDW (Етап 4)
         Джерело даних куба (Polyclinic DW.ds) використовує режим
         ImpersonateServiceAccount: під час обробки (Process) і ROLAP-запитів
         SSAS підключається до SQL Server від імені свого службового облікового запису.
   Запуск: SSMS, підключення до DESKTOP-I5COGTD (Database Engine), один раз.
   ===================================================================== */
USE master;
GO
IF SUSER_ID(N'NT Service\MSSQLServerOLAPService') IS NULL
    CREATE LOGIN [NT Service\MSSQLServerOLAPService] FROM WINDOWS WITH DEFAULT_DATABASE = [PolyclinicDW];
GO
USE PolyclinicDW;
GO
IF USER_ID(N'NT Service\MSSQLServerOLAPService') IS NULL
    CREATE USER [NT Service\MSSQLServerOLAPService] FOR LOGIN [NT Service\MSSQLServerOLAPService];
ALTER ROLE db_datareader ADD MEMBER [NT Service\MSSQLServerOLAPService];
GO
-- Перевірка
SELECT dp.name AS UserName, r.name AS RoleName
FROM sys.database_role_members rm
JOIN sys.database_principals r  ON r.principal_id  = rm.role_principal_id
JOIN sys.database_principals dp ON dp.principal_id = rm.member_principal_id
WHERE dp.name = N'NT Service\MSSQLServerOLAPService';
GO
