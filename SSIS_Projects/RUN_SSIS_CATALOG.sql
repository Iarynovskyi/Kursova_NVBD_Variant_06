/* =====================================================================
   Файл: RUN_SSIS_CATALOG.sql
   Опис: Запуск розгорнутого SSIS-проєкту Polyclinic_ETL з каталогу SSISDB
         та перегляд журналів виконання (Етап 3)
   Розгортання: Visual Studio → проєкт Polyclinic_ETL → Deploy
                (Integration Services Deployment Wizard → SSISDB\Polyclinic)
   Підключення: SQL Server з Windows-автентифікацією (вимога каталогу SSISDB)
   Параметри запуску:
     @LoadType          — 'Full' (повне перезавантаження) або 'Incremental'
     @SimulateFailureAt — ім'я пакета для імітації збою (тест checkpoint) або ''
   ===================================================================== */
USE SSISDB;
GO
SET NOCOUNT ON;

DECLARE @LoadType NVARCHAR(20) = N'Full',
        @SimulateFailureAt NVARCHAR(100) = N'';

DECLARE @Exec BIGINT;
EXEC catalog.create_execution @folder_name = N'Polyclinic', @project_name = N'Polyclinic_ETL', @package_name = N'Master.dtsx',
     @use32bitruntime = 0, @execution_id = @Exec OUTPUT;
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 50, @parameter_name = N'SYNCHRONIZED', @parameter_value = 1;
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 50, @parameter_name = N'LOGGING_LEVEL', @parameter_value = 1;  -- Basic
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 20, @parameter_name = N'LoadType', @parameter_value = @LoadType;
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 20, @parameter_name = N'SimulateFailureAt', @parameter_value = @SimulateFailureAt;
EXEC catalog.start_execution @Exec;

-- Результат запуску (7 = Succeeded, 4 = Failed)
SELECT e.execution_id, e.package_name, e.status,
       CASE e.status WHEN 7 THEN N'Успішно' WHEN 4 THEN N'Помилка' WHEN 2 THEN N'Виконується' ELSE CAST(e.status AS NVARCHAR(10)) END AS StatusName,
       DATEDIFF(SECOND, e.start_time, e.end_time) AS DurationSec
FROM catalog.executions e WHERE e.execution_id = @Exec;

-- Помилки та попередження
SELECT em.event_name, em.package_name, em.message_source_name, em.message
FROM catalog.event_messages em
WHERE em.operation_id = @Exec AND em.event_name IN (N'OnError', N'OnWarning', N'OnTaskFailed')
ORDER BY em.event_message_id;

-- Власний аудит ETL (PolyclinicDW.etl)
SELECT TOP (10) * FROM PolyclinicDW.etl.vw_ExecutionHistory ORDER BY ExecutionID DESC;
SELECT TOP (30) t.ExecutionID, t.TaskName, t.RowsRead, t.RowsInserted, t.RowsUpdated, t.RowsRejected, t.Notes
FROM PolyclinicDW.etl.TaskLog t ORDER BY t.TaskLogID DESC;
GO
