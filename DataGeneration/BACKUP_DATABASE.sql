/* =====================================================================
   Файл: BACKUP_DATABASE.sql
   Опис: Резервне копіювання згенерованих даних (Етап 2.3)
         • повна резервна копія PolyclinicOLTP (та PolyclinicDW, якщо існує)
         • COMPRESSION (якщо підтримує редакція сервера) + CHECKSUM
         • перевірка придатності копії RESTORE VERIFYONLY
         • файли зберігаються у стандартній папці резервних копій екземпляра
   ===================================================================== */

USE master;
GO

SET NOCOUNT ON;

DECLARE @BackupDir NVARCHAR(500) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(500));
IF @BackupDir IS NULL OR @BackupDir = N''
    THROW 50100, N'Не вдалося визначити стандартну папку резервних копій сервера (InstanceDefaultBackupPath).', 1;
IF RIGHT(@BackupDir, 1) <> N'\' SET @BackupDir += N'\';

-- Стиснення резервних копій недоступне в редакції Express (EngineEdition = 4)
DECLARE @CanCompress BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 4 THEN 0 ELSE 1 END;
DECLARE @Stamp NVARCHAR(20) = FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmmss');

DECLARE @Db SYSNAME, @File NVARCHAR(600), @Sql NVARCHAR(MAX);
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE name IN (N'PolyclinicOLTP', N'PolyclinicDW') ORDER BY name DESC;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @File = @BackupDir + @Db + N'_FULL_' + @Stamp + N'.bak';

    SET @Sql = N'BACKUP DATABASE ' + QUOTENAME(@Db) + N' TO DISK = @f WITH INIT, FORMAT, CHECKSUM'
             + CASE WHEN @CanCompress = 1 THEN N', COMPRESSION' ELSE N'' END
             + N', NAME = @n, DESCRIPTION = @d, STATS = 25;';
    DECLARE @Name NVARCHAR(128) = @Db + N' — повна резервна копія (Етап 2.3)';
    DECLARE @Desc NVARCHAR(255) = N'Курсова NVBD, варіант 6 "Поліклініка": згенеровані дані';
    EXEC sys.sp_executesql @Sql, N'@f NVARCHAR(600), @n NVARCHAR(128), @d NVARCHAR(255)', @f = @File, @n = @Name, @d = @Desc;

    SET @Sql = N'RESTORE VERIFYONLY FROM DISK = @f WITH CHECKSUM;';
    EXEC sys.sp_executesql @Sql, N'@f NVARCHAR(600)', @f = @File;

    PRINT N'Резервну копію створено та перевірено: ' + @File;
    FETCH NEXT FROM db_cursor INTO @Db;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;
GO

/* Історія резервних копій (для скріншоту у звіт) */
SELECT TOP (10)
    bs.database_name                                   AS DatabaseName,
    bs.backup_start_date                               AS BackupStart,
    bs.backup_finish_date                              AS BackupFinish,
    CAST(bs.backup_size / 1048576.0 AS DECIMAL(12,1))  AS BackupSizeMB,
    CAST(bs.compressed_backup_size / 1048576.0 AS DECIMAL(12,1)) AS CompressedSizeMB,
    bmf.physical_device_name                           AS BackupFile
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name IN (N'PolyclinicOLTP', N'PolyclinicDW')
ORDER BY bs.backup_finish_date DESC;
GO

/* ---------------------------------------------------------------------
   Відновлення (за потреби виконати вручну, підставивши ім'я файлу):
   RESTORE DATABASE PolyclinicOLTP FROM DISK = N'<шлях>\PolyclinicOLTP_FULL_yyyyMMdd_HHmmss.bak'
       WITH REPLACE, RECOVERY, STATS = 10;
   --------------------------------------------------------------------- */
