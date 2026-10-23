/* =====================================================================
   Файл: TEST_SSIS_INCREMENTAL.sql
   Опис: Тест інкрементального завантаження SSIS-проєкту Polyclinic_ETL (Етап 3)
     1. Знімок кількостей у PolyclinicDW до тесту.
     2. Нові операційні дані в PolyclinicOLTP (через процедури бізнес-логіки):
        - зміна адреси пацієнта                (SCD Type 2 -> нова версія DimPatient);
        - підвищення категорії лікаря          (SCD Type 2 -> нова версія DimDoctor);
        - закриття незавершеного випадку       (UPDATE рядка FactVisits);
        - новий візит + діагноз + рецепт       (INSERT у FactVisits і FactPrescriptions).
     3. Запуск Master.dtsx з каталогу SSISDB з параметром LoadType = 'Incremental'.
     4. Перевірки PASS / FAIL: витягнуто лише змінені рядки (watermark),
        SCD2-версії, UPSERT без дублів, архів Філії №2 повторно не завантажується.
   Передумова: проєкт розгорнуто у SSISDB\Polyclinic і виконано повне завантаження
               (RUN_SSIS_CATALOG.sql з @LoadType = 'Full').
   Примітка: зміни в OLTP лишаються (це «нові дані дня»), тому скрипт можна запускати
             повторно — щоразу обираються інші записи, перевірки відносні.
   ===================================================================== */
USE SSISDB;
SET NOCOUNT ON;

/* ---------- 1. Знімок до тесту ---------- */
DECLARE @FvOltp INT, @FvBranch INT, @Fp INT, @MonthVisits INT;
SELECT @FvOltp   = COUNT(*) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'OLTP';
SELECT @FvBranch = COUNT(*) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'BRANCH2';
SELECT @Fp       = COUNT(*) FROM PolyclinicDW.dbo.FactPrescriptions;

/* ---------- 2. Нові дані в OLTP ---------- */
DECLARE @Pat INT, @Doc INT, @OpenDiag BIGINT, @Dis INT, @Med INT, @NewVisit BIGINT, @NewDiag BIGINT;
DECLARE @PatVer0 INT, @DocVer0 INT;
-- Візит датовано «через годину від зараз» — після моменту зміни атрибутів SCD2
DECLARE @VisitDT DATETIME2(0) = DATEADD(HOUR, 1, CAST(SYSDATETIME() AS DATETIME2(0)));

SELECT TOP (1) @Pat = p.PatientID FROM PolyclinicOLTP.dbo.Patients p
WHERE EXISTS (SELECT 1 FROM PolyclinicOLTP.dbo.Visits v WHERE v.PatientID = p.PatientID) AND p.BirthDate < '2000-01-01'
ORDER BY p.PatientID DESC;
SELECT TOP (1) @Doc = d.DoctorID FROM PolyclinicOLTP.dbo.Doctors d
WHERE d.IsActive = 1 AND d.SpecialtyID = 1 AND d.QualificationCategory <> N'Вища' ORDER BY d.DoctorID DESC;
SELECT TOP (1) @OpenDiag = DiagnosisID FROM PolyclinicOLTP.dbo.Diagnoses WHERE TreatmentOutcome = N'В процесі' ORDER BY DiagnosisID DESC;
SELECT @Dis = DiseaseID FROM PolyclinicOLTP.dbo.Diseases WHERE ICD10Code = 'J06.9';
SELECT TOP (1) @Med = m.MedicationID FROM PolyclinicOLTP.dbo.Medications m
WHERE m.ActiveSubstance LIKE N'Парацетамол%'
  AND NOT EXISTS (SELECT 1 FROM PolyclinicOLTP.dbo.PatientContraindications pc WHERE pc.PatientID = @Pat AND pc.MedicationID = m.MedicationID)
ORDER BY m.MedicationID;
SELECT @PatVer0 = COUNT(*) FROM PolyclinicDW.dbo.DimPatient WHERE PatientID_Source = @Pat;
SELECT @DocVer0 = COUNT(*) FROM PolyclinicDW.dbo.DimDoctor  WHERE DoctorID_Source  = @Doc;

UPDATE PolyclinicOLTP.dbo.Patients SET AddressLine = CONCAT(N'м. Львів, вул. Інкрементальна, буд. ', @Pat % 100 + 1) WHERE PatientID = @Pat;
UPDATE PolyclinicOLTP.dbo.Doctors  SET QualificationCategory = N'Вища' WHERE DoctorID = @Doc;
DECLARE @Today DATE = CAST(SYSDATETIME() AS DATE);
EXEC PolyclinicOLTP.dbo.usp_CloseDiagnosisCase @DiagnosisID = @OpenDiag, @TreatmentOutcome = N'Одужання', @RecoveryDate = @Today;
EXEC PolyclinicOLTP.dbo.usp_RegisterVisitAndDiagnosis
     @PatientID = @Pat, @DoctorID = @Doc, @VisitDateTime = @VisitDT, @VisitType = N'Первинний',
     @DurationMinutes = 30, @IsFreeNSZU = 0, @Complaints = N'Тест інкрементального SSIS-завантаження', @DiseaseID = @Dis,
     @Severity = N'Легка', @SickLeaveDays = 3, @NewVisitID = @NewVisit OUTPUT, @NewDiagnosisID = @NewDiag OUTPUT;
EXEC PolyclinicOLTP.dbo.usp_PrescribeMedication @DiagnosisID = @NewDiag, @MedicationID = @Med,
     @DailyDosage = N'По 1 таблетці 3 рази на добу', @DurationDays = 5, @QuantityPackages = 1, @IsSubsidized = 0;

/* ---------- 3. Інкрементальний запуск Master.dtsx ---------- */
DECLARE @Exec BIGINT;
EXEC catalog.create_execution @folder_name = N'Polyclinic', @project_name = N'Polyclinic_ETL', @package_name = N'Master.dtsx',
     @use32bitruntime = 0, @execution_id = @Exec OUTPUT;
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 50, @parameter_name = N'SYNCHRONIZED', @parameter_value = 1;
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 20, @parameter_name = N'LoadType', @parameter_value = N'Incremental';
EXEC catalog.set_execution_parameter_value @Exec, @object_type = 20, @parameter_name = N'SimulateFailureAt', @parameter_value = N'';
EXEC catalog.start_execution @Exec;

/* ---------- 4. Перевірки ---------- */
DECLARE @Status INT = (SELECT status FROM catalog.executions WHERE execution_id = @Exec);
DECLARE @Master INT = (SELECT MAX(ExecutionID) FROM PolyclinicDW.etl.PackageExecutionLog WHERE PackageName = N'Master');
DECLARE @Runs TABLE (ExecutionID INT PRIMARY KEY);
INSERT INTO @Runs SELECT ExecutionID FROM PolyclinicDW.etl.PackageExecutionLog WHERE ExecutionID = @Master OR ParentExecutionID = @Master;

DECLARE @FvRead INT, @FvIns INT, @FvUpd INT, @FpIns INT;
SELECT @FvRead = SUM(t.RowsRead), @FvIns = SUM(t.RowsInserted), @FvUpd = SUM(t.RowsUpdated)
FROM PolyclinicDW.etl.TaskLog t JOIN @Runs r ON r.ExecutionID = t.ExecutionID WHERE t.TaskName = N'FactVisits (MERGE, SSIS)';
SELECT @FpIns = SUM(t.RowsInserted)
FROM PolyclinicDW.etl.TaskLog t JOIN @Runs r ON r.ExecutionID = t.ExecutionID WHERE t.TaskName = N'FactPrescriptions (MERGE, SSIS)';

DECLARE @Checks TABLE (CheckID INT IDENTITY(1,1), CheckName NVARCHAR(200), Expected NVARCHAR(60), Actual NVARCHAR(60), Passed BIT);
INSERT INTO @Checks (CheckName, Expected, Actual, Passed) VALUES
 (N'Master.dtsx (Incremental) завершився успішно', N'status 7', CONCAT(N'status ', @Status), IIF(@Status = 7, 1, 0)),
 (N'Пакет Master і 5 дочірніх пакетів у журналі etl зі статусом Success', N'6',
  (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM PolyclinicDW.etl.PackageExecutionLog l JOIN @Runs r ON r.ExecutionID = l.ExecutionID WHERE l.ExecutionStatus = N'Success'),
  IIF((SELECT COUNT(*) FROM PolyclinicDW.etl.PackageExecutionLog l JOIN @Runs r ON r.ExecutionID = l.ExecutionID WHERE l.ExecutionStatus = N'Success') = 6, 1, 0)),
 (N'Watermark: з OLTP прочитано лише змінені діагнози (новий + закритий)', N'2..10', CAST(@FvRead AS NVARCHAR(10)), IIF(@FvRead BETWEEN 2 AND 10, 1, 0)),
 (N'FactVisits: вставлено 1 новий рядок, решта — UPDATE', N'1 / >= 1', CONCAT(@FvIns, N' / ', @FvUpd), IIF(@FvIns = 1 AND @FvUpd >= 1, 1, 0)),
 (N'FactVisits (OLTP) +1 рядок без дублів', CAST(@FvOltp + 1 AS NVARCHAR(10)),
  (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'OLTP'),
  IIF((SELECT COUNT(*) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'OLTP') = @FvOltp + 1, 1, 0)),
 (N'FactPrescriptions +1 рядок', CAST(@Fp + 1 AS NVARCHAR(10)), (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM PolyclinicDW.dbo.FactPrescriptions),
  IIF((SELECT COUNT(*) FROM PolyclinicDW.dbo.FactPrescriptions) = @Fp + 1 AND @FpIns = 1, 1, 0)),
 (N'Архів Філії №2 повторно не завантажено (файли вже зареєстровані)', CAST(@FvBranch AS NVARCHAR(10)),
  (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'BRANCH2'),
  IIF((SELECT COUNT(*) FROM PolyclinicDW.dbo.FactVisits WHERE SourceSystem = N'BRANCH2') = @FvBranch, 1, 0)),
 (N'SCD2 DimPatient: додано нову поточну версію з новою адресою', CAST(@PatVer0 + 1 AS NVARCHAR(10)),
  (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM PolyclinicDW.dbo.DimPatient WHERE PatientID_Source = @Pat),
  IIF((SELECT COUNT(*) FROM PolyclinicDW.dbo.DimPatient WHERE PatientID_Source = @Pat) = @PatVer0 + 1
      AND EXISTS (SELECT 1 FROM PolyclinicDW.dbo.DimPatient WHERE PatientID_Source = @Pat AND IsCurrent = 1 AND AddressLine LIKE N'%Інкрементальна%'), 1, 0)),
 (N'SCD2 DimDoctor: додано нову поточну версію з категорією «Вища»', CAST(@DocVer0 + 1 AS NVARCHAR(10)),
  (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM PolyclinicDW.dbo.DimDoctor WHERE DoctorID_Source = @Doc),
  IIF((SELECT COUNT(*) FROM PolyclinicDW.dbo.DimDoctor WHERE DoctorID_Source = @Doc) = @DocVer0 + 1
      AND EXISTS (SELECT 1 FROM PolyclinicDW.dbo.DimDoctor WHERE DoctorID_Source = @Doc AND IsCurrent = 1 AND QualificationCategory = N'Вища'), 1, 0)),
 (N'Новий факт прив''язаний до поточних версій пацієнта і лікаря, вартість 30 хв за ставкою', N'так',
  IIF(EXISTS (SELECT 1 FROM PolyclinicDW.dbo.FactVisits f
              JOIN PolyclinicDW.dbo.DimPatient p ON p.PatientKey = f.PatientKey AND p.IsCurrent = 1
              JOIN PolyclinicDW.dbo.DimDoctor  d ON d.DoctorKey  = f.DoctorKey  AND d.IsCurrent = 1
              WHERE f.DiagnosisID_Source = @NewDiag AND f.ConsultationCostUAH = CAST(d.HourlyRate / 2 AS DECIMAL(10,2))), N'так', N'ні'),
  IIF(EXISTS (SELECT 1 FROM PolyclinicDW.dbo.FactVisits f
              JOIN PolyclinicDW.dbo.DimPatient p ON p.PatientKey = f.PatientKey AND p.IsCurrent = 1
              JOIN PolyclinicDW.dbo.DimDoctor  d ON d.DoctorKey  = f.DoctorKey  AND d.IsCurrent = 1
              WHERE f.DiagnosisID_Source = @NewDiag AND f.ConsultationCostUAH = CAST(d.HourlyRate / 2 AS DECIMAL(10,2))), 1, 0)),
 (N'Закритий випадок оновлено у факті (IsRecoveredFlag = 1)', N'так',
  IIF(EXISTS (SELECT 1 FROM PolyclinicDW.dbo.FactVisits WHERE DiagnosisID_Source = @OpenDiag AND SourceSystem = N'OLTP' AND IsRecoveredFlag = 1), N'так', N'ні'),
  IIF(EXISTS (SELECT 1 FROM PolyclinicDW.dbo.FactVisits WHERE DiagnosisID_Source = @OpenDiag AND SourceSystem = N'OLTP' AND IsRecoveredFlag = 1), 1, 0)),
 (N'Місячний агрегат узгоджений з фактом після інкременту', CAST((SELECT SUM(VisitCount) FROM PolyclinicDW.dbo.FactVisits) AS NVARCHAR(20)),
  CAST((SELECT SUM(TotalVisitsCount) FROM PolyclinicDW.dbo.FactDoctorMonthlySummary) AS NVARCHAR(20)),
  IIF((SELECT SUM(VisitCount) FROM PolyclinicDW.dbo.FactVisits) = (SELECT SUM(TotalVisitsCount) FROM PolyclinicDW.dbo.FactDoctorMonthlySummary), 1, 0));

SELECT CheckID, CheckName, Expected, Actual, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Status FROM @Checks ORDER BY CheckID;

-- Журнал задач інкрементального запуску та помилки SSIS (якщо були)
SELECT t.ExecutionID, t.TaskName, t.RowsRead, t.RowsInserted, t.RowsUpdated, t.RowsRejected, t.Notes
FROM PolyclinicDW.etl.TaskLog t JOIN @Runs r ON r.ExecutionID = t.ExecutionID ORDER BY t.TaskLogID;
SELECT em.package_name, em.message_source_name, em.message FROM catalog.event_messages em
WHERE em.operation_id = @Exec AND em.event_name IN (N'OnError', N'OnTaskFailed') ORDER BY em.event_message_id;

DECLARE @Failed INT = (SELECT COUNT(*) FROM @Checks WHERE Passed = 0);
IF @Failed > 0 RAISERROR(N'TEST_SSIS_INCREMENTAL: не пройдено перевірок: %d', 16, 1, @Failed);
ELSE PRINT N'TEST_SSIS_INCREMENTAL: усі перевірки пройдено.';
