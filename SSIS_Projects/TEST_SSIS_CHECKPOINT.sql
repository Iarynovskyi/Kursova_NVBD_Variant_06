/* =====================================================================
   Файл: TEST_SSIS_CHECKPOINT.sql
   Опис: Тест відновлення після збою (checkpoint) пакета Master.dtsx (Етап 3)
     Запуск 1: LoadType = 'Full', SimulateFailureAt = 'Fact_Prescriptions'
               -> виміри та Fact_Visits завантажено, Fact_Prescriptions падає,
                  Master завершується з помилкою і зберігає Master.chk
                  (параметр проєкту CheckpointFolder).
     Запуск 2: ті самі параметри, але SimulateFailureAt = ''
               -> Master продовжує з контрольної точки: «SQL Повне перезавантаження»,
                  «SEQ Виміри» та вже завершений «EPT Fact_Visits» пропускаються,
                  виконується лише задача, що впала («EPT Fact_Prescriptions»), і далі
                  «SEQ Агрегати». Точки рестарту — задачі Execute Package з
                  FailPackageOnFailure = True (див. Master.dtsx).
     Перевірки PASS / FAIL: статуси запусків, пропущені задачі, повнота даних.
   Передумова: проєкт розгорнуто у SSISDB\Polyclinic, обліковий запис служби SQL Server
               має право запису в CheckpointFolder.
   Тривалість: близько 3–5 хвилин.
   ===================================================================== */
USE SSISDB;
SET NOCOUNT ON;

DECLARE @Run1 BIGINT, @Run2 BIGINT;

/* ---------- Запуск 1: імітований збій у Fact_Prescriptions ---------- */
EXEC catalog.create_execution @folder_name = N'Polyclinic', @project_name = N'Polyclinic_ETL', @package_name = N'Master.dtsx',
     @use32bitruntime = 0, @execution_id = @Run1 OUTPUT;
EXEC catalog.set_execution_parameter_value @Run1, @object_type = 50, @parameter_name = N'SYNCHRONIZED', @parameter_value = 1;
EXEC catalog.set_execution_parameter_value @Run1, @object_type = 20, @parameter_name = N'LoadType', @parameter_value = N'Full';
EXEC catalog.set_execution_parameter_value @Run1, @object_type = 20, @parameter_name = N'SimulateFailureAt', @parameter_value = N'Fact_Prescriptions';
EXEC catalog.start_execution @Run1;

DECLARE @PrescAfterFail INT = (SELECT COUNT(*) FROM PolyclinicDW.dbo.FactPrescriptions);
DECLARE @VisitsAfterFail INT = (SELECT COUNT(*) FROM PolyclinicDW.dbo.FactVisits);

/* ---------- Запуск 2: повторний запуск після «усунення» збою ---------- */
EXEC catalog.create_execution @folder_name = N'Polyclinic', @project_name = N'Polyclinic_ETL', @package_name = N'Master.dtsx',
     @use32bitruntime = 0, @execution_id = @Run2 OUTPUT;
EXEC catalog.set_execution_parameter_value @Run2, @object_type = 50, @parameter_name = N'SYNCHRONIZED', @parameter_value = 1;
EXEC catalog.set_execution_parameter_value @Run2, @object_type = 20, @parameter_name = N'LoadType', @parameter_value = N'Full';
EXEC catalog.set_execution_parameter_value @Run2, @object_type = 20, @parameter_name = N'SimulateFailureAt', @parameter_value = N'';
EXEC catalog.start_execution @Run2;

/* ---------- Перевірки ---------- */
DECLARE @S1 INT = (SELECT status FROM catalog.executions WHERE execution_id = @Run1),
        @S2 INT = (SELECT status FROM catalog.executions WHERE execution_id = @Run2);
DECLARE @SimErr INT = (SELECT COUNT(*) FROM catalog.event_messages WHERE operation_id = @Run1 AND event_name = N'OnError' AND message LIKE N'%Імітація збою%');
-- Задачі, виконані у запуску 2 (пропущені за checkpoint у статистиці відсутні)
DECLARE @R2Reset INT = (SELECT COUNT(*) FROM catalog.executable_statistics WHERE execution_id = @Run2 AND execution_path LIKE N'%SQL Повне перезавантаження%');
DECLARE @R2Dims  INT = (SELECT COUNT(*) FROM catalog.executable_statistics WHERE execution_id = @Run2 AND execution_path LIKE N'%SEQ Виміри%');
DECLARE @R2Visits INT = (SELECT COUNT(*) FROM catalog.executable_statistics WHERE execution_id = @Run2 AND execution_path LIKE N'%EPT Fact_Visits%');
DECLARE @R2Facts INT = (SELECT COUNT(*) FROM catalog.executable_statistics WHERE execution_id = @Run2 AND execution_path LIKE N'%EPT Fact_Prescriptions%');
DECLARE @R2Aggr  INT = (SELECT COUNT(*) FROM catalog.executable_statistics WHERE execution_id = @Run2 AND execution_path LIKE N'%EPT Fact_DoctorMonthly%');

DECLARE @OltpDiag INT = (SELECT COUNT(*) FROM PolyclinicOLTP.dbo.Diagnoses),
        @OltpPresc INT = (SELECT COUNT(*) FROM PolyclinicOLTP.dbo.Prescriptions),
        @FvOltp INT = (SELECT COUNT(*) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'OLTP'),
        @FvBranch INT = (SELECT COUNT(*) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'BRANCH2'),
        @Fp INT = (SELECT COUNT(*) FROM PolyclinicDW.dbo.FactPrescriptions),
        @Dups INT = (SELECT COUNT(*) FROM (SELECT SourceSystem, DiagnosisID_Source FROM PolyclinicDW.dbo.FactVisits
                                           GROUP BY SourceSystem, DiagnosisID_Source HAVING COUNT(*) > 1) d);

DECLARE @Checks TABLE (CheckID INT IDENTITY(1,1), CheckName NVARCHAR(200), Expected NVARCHAR(60), Actual NVARCHAR(60), Passed BIT);
INSERT INTO @Checks (CheckName, Expected, Actual, Passed) VALUES
 (N'Запуск 1 завершився помилкою (status 4)', N'4', CAST(@S1 AS NVARCHAR(5)), IIF(@S1 = 4, 1, 0)),
 (N'Причина — імітований збій у Fact_Prescriptions', N'>= 1', CAST(@SimErr AS NVARCHAR(10)), IIF(@SimErr >= 1, 1, 0)),
 (N'Після збою факт візитів є, факт рецептів порожній', N'> 0 / 0', CONCAT(@VisitsAfterFail, N' / ', @PrescAfterFail), IIF(@VisitsAfterFail > 0 AND @PrescAfterFail = 0, 1, 0)),
 (N'Запуск 2 завершився успішно (status 7)', N'7', CAST(@S2 AS NVARCHAR(5)), IIF(@S2 = 7, 1, 0)),
 (N'Запуск 2: «SQL Повне перезавантаження» пропущено (checkpoint)', N'0', CAST(@R2Reset AS NVARCHAR(10)), IIF(@R2Reset = 0, 1, 0)),
 (N'Запуск 2: «SEQ Виміри» пропущено (checkpoint)', N'0', CAST(@R2Dims AS NVARCHAR(10)), IIF(@R2Dims = 0, 1, 0)),
 (N'Запуск 2: завершений до збою Fact_Visits пропущено (checkpoint)', N'0', CAST(@R2Visits AS NVARCHAR(10)), IIF(@R2Visits = 0, 1, 0)),
 (N'Запуск 2: Fact_Prescriptions і Fact_DoctorMonthly виконано', N'>= 1 / >= 1', CONCAT(@R2Facts, N' / ', @R2Aggr), IIF(@R2Facts >= 1 AND @R2Aggr >= 1, 1, 0)),
 (N'FactVisits (OLTP) = OLTP.Diagnoses', CAST(@OltpDiag AS NVARCHAR(10)), CAST(@FvOltp AS NVARCHAR(10)), IIF(@FvOltp = @OltpDiag, 1, 0)),
 (N'FactVisits (BRANCH2) після рестарту не втрачено', N'> 0', CAST(@FvBranch AS NVARCHAR(10)), IIF(@FvBranch > 0, 1, 0)),
 (N'FactPrescriptions = OLTP.Prescriptions', CAST(@OltpPresc AS NVARCHAR(10)), CAST(@Fp AS NVARCHAR(10)), IIF(@Fp = @OltpPresc, 1, 0)),
 (N'Дублікати фактів після рестарту', N'0', CAST(@Dups AS NVARCHAR(10)), IIF(@Dups = 0, 1, 0));

SELECT CheckID, CheckName, Expected, Actual, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Status FROM @Checks ORDER BY CheckID;

-- Що виконувалось у кожному запуску
SELECT s.execution_id, s.execution_path,
       CASE s.execution_result WHEN 0 THEN N'Success' WHEN 1 THEN N'Failure' WHEN 2 THEN N'Completion' WHEN 3 THEN N'Cancelled' END AS Result,
       s.execution_duration AS DurationMs
FROM catalog.executable_statistics s
WHERE s.execution_id IN (@Run1, @Run2) AND s.execution_path LIKE N'\Master\%' AND s.execution_path NOT LIKE N'\Master\%\%\%'
ORDER BY s.execution_id, s.start_time;
SELECT em.operation_id, em.package_name, em.message_source_name, em.message FROM catalog.event_messages em
WHERE em.operation_id IN (@Run1, @Run2) AND em.event_name = N'OnError' ORDER BY em.event_message_id;

DECLARE @Failed INT = (SELECT COUNT(*) FROM @Checks WHERE Passed = 0);
IF @Failed > 0 RAISERROR(N'TEST_SSIS_CHECKPOINT: не пройдено перевірок: %d', 16, 1, @Failed);
ELSE PRINT N'TEST_SSIS_CHECKPOINT: усі перевірки пройдено.';
