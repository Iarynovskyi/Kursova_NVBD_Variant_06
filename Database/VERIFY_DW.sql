/* =====================================================================
   Файл: VERIFY_DW.sql
   Опис: Смоук-тест сховища PolyclinicDW та ETL (Етап 3, «Перевірка коректності ETL-трансформацій»)
     A. Структура зірки та невідомі члени вимірів
     B. Звірка OLTP ↔ DW після повного завантаження (кількості, суми, ключі)
     C. Цілісність SCD Type 2 (одна поточна версія, інтервали без перекриттів)
     D. Інкрементальний сценарій у транзакції з ROLLBACK (дані не змінюються):
        зміна адреси пацієнта (SCD2), категорії лікаря (SCD2), закриття випадку,
        новий візит + рецепт -> інкрементальний ETL -> перевірки -> відкат
     E. Підсумок PASS / FAIL (RAISERROR при помилках)
   Передумова: виконано RUN_ETL_PIPELINE.sql (повне завантаження).
   ===================================================================== */

USE PolyclinicDW;
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DROP TABLE IF EXISTS #Checks;
CREATE TABLE #Checks (
    CheckID INT IDENTITY(1,1) PRIMARY KEY, CheckGroup NVARCHAR(40) NOT NULL, CheckName NVARCHAR(200) NOT NULL,
    Expected NVARCHAR(60) NOT NULL, Actual NVARCHAR(60) NULL, Passed BIT NOT NULL,
    Status AS (CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END));
GO

/* ---------------------------------------------------------------------
   A. СТРУКТУРА
   --------------------------------------------------------------------- */
DECLARE @dims INT = (SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID('dbo') AND name LIKE 'Dim%');
DECLARE @facts INT = (SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID('dbo') AND name LIKE 'Fact%');
DECLARE @unk INT = (SELECT COUNT(*) FROM dbo.DimPatient WHERE PatientKey = -1) + (SELECT COUNT(*) FROM dbo.DimDoctor WHERE DoctorKey = -1)
                 + (SELECT COUNT(*) FROM dbo.DimDisease WHERE DiseaseKey = -1) + (SELECT COUNT(*) FROM dbo.DimMedication WHERE MedicationKey = -1)
                 + (SELECT COUNT(*) FROM dbo.DimAgeGroup WHERE AgeGroupKey = -1) + (SELECT COUNT(*) FROM dbo.DimClinicalOutcome WHERE OutcomeKey = -1)
                 + (SELECT COUNT(*) FROM dbo.DimDate WHERE DateKey = 19000101);
DECLARE @hol INT = (SELECT COUNT(*) FROM dbo.DimDate WHERE FullDate IN ('2024-08-24', '2024-01-01', '2024-05-05') AND IsHoliday = 1 AND WorkingDayStatus = N'Свято');
DECLARE @holMismatch INT = (SELECT COUNT(*) FROM dbo.DimDate WHERE (IsHoliday = 1 AND WorkingDayStatus <> N'Свято') OR (IsHoliday = 0 AND WorkingDayStatus = N'Свято'));

INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES
 (N'A. Структура', N'Таблиць вимірів (мін. 5)', N'>= 5', CAST(@dims AS NVARCHAR(10)), IIF(@dims >= 5, 1, 0)),
 (N'A. Структура', N'Таблиць фактів (мін. 2)', N'>= 2', CAST(@facts AS NVARCHAR(10)), IIF(@facts >= 2, 1, 0)),
 (N'A. Структура', N'Невідомі члени в усіх 7 вимірах', N'7', CAST(@unk AS NVARCHAR(10)), IIF(@unk = 7, 1, 0)),
 (N'A. Структура', N'Свята в DimDate (24.08, 01.01, Великдень 2024)', N'3', CAST(@hol AS NVARCHAR(10)), IIF(@hol = 3, 1, 0)),
 (N'A. Структура', N'Узгодженість IsHoliday ⇔ WorkingDayStatus', N'0', CAST(@holMismatch AS NVARCHAR(10)), IIF(@holMismatch = 0, 1, 0));
GO

/* ---------------------------------------------------------------------
   B. ЗВІРКА OLTP ↔ DW
   --------------------------------------------------------------------- */
DECLARE @a BIGINT, @b BIGINT, @x DECIMAL(18,2), @y DECIMAL(18,2);

SELECT @a = COUNT(*) FROM PolyclinicOLTP.dbo.Diagnoses;
SELECT @b = COUNT(*) FROM dbo.FactVisits WHERE SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Звірка', N'FactVisits(OLTP) = OLTP.Diagnoses', CAST(@a AS NVARCHAR(20)), CAST(@b AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

SELECT @a = COUNT(*) FROM PolyclinicOLTP.dbo.Visits;
SELECT @b = SUM(VisitCount) FROM dbo.FactVisits WHERE SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Звірка', N'SUM(VisitCount) = OLTP.Visits', CAST(@a AS NVARCHAR(20)), CAST(@b AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

SELECT @a = COUNT(*) FROM PolyclinicOLTP.dbo.Prescriptions;
SELECT @b = COUNT(*) FROM dbo.FactPrescriptions WHERE SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Звірка', N'FactPrescriptions = OLTP.Prescriptions', CAST(@a AS NVARCHAR(20)), CAST(@b AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

SELECT @a = COUNT(*) FROM PolyclinicOLTP.dbo.Patients;
SELECT @b = COUNT(*) FROM dbo.DimPatient WHERE IsCurrent = 1 AND PatientKey <> -1;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Поточні версії DimPatient = OLTP.Patients', CAST(@a AS NVARCHAR(20)), CAST(@b AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

SELECT @a = (SELECT COUNT(*) FROM PolyclinicOLTP.dbo.Doctors) + (SELECT COUNT(*) FROM PolyclinicOLTP.dbo.Medications) + (SELECT COUNT(*) FROM PolyclinicOLTP.dbo.Diseases);
SELECT @b = (SELECT COUNT(*) FROM dbo.DimDoctor WHERE IsCurrent = 1 AND DoctorKey <> -1) + (SELECT COUNT(*) FROM dbo.DimMedication WHERE MedicationKey <> -1)
          + (SELECT COUNT(*) FROM dbo.DimDisease WHERE DiseaseKey <> -1);
INSERT INTO #Checks VALUES (N'B. Звірка', N'DimDoctor + DimMedication + DimDisease = OLTP', CAST(@a AS NVARCHAR(20)), CAST(@b AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

-- Вартість прийомів: DW = перерахунок у OLTP (ставка спеціальності × тривалість, безкоштовні = 0)
SELECT @x = SUM(CAST(CASE WHEN v.IsFreeNSZU = 0 THEN v.DurationMinutes / 60.0 * sp.HourlyRate ELSE 0 END AS DECIMAL(10,2)))
FROM PolyclinicOLTP.dbo.Visits v JOIN PolyclinicOLTP.dbo.Doctors d ON d.DoctorID = v.DoctorID JOIN PolyclinicOLTP.dbo.Specialties sp ON sp.SpecialtyID = d.SpecialtyID;
SELECT @y = SUM(ConsultationCostUAH) FROM dbo.FactVisits WHERE SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Сума вартості прийомів OLTP = DW (грн)', CAST(@x AS NVARCHAR(30)), CAST(@y AS NVARCHAR(30)), IIF(@x = @y, 1, 0));

SELECT @x = SUM(CAST(pr.QuantityPackages * m.UnitPrice AS DECIMAL(18,2)))
FROM PolyclinicOLTP.dbo.Prescriptions pr JOIN PolyclinicOLTP.dbo.Medications m ON m.MedicationID = pr.MedicationID;
SELECT @y = SUM(TotalMedicationCostUAH) FROM dbo.FactPrescriptions WHERE SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Сума вартості рецептів OLTP = DW (грн)', CAST(@x AS NVARCHAR(30)), CAST(@y AS NVARCHAR(30)), IIF(@x = @y, 1, 0));

SELECT @a = SUM(SickLeaveDays) FROM PolyclinicOLTP.dbo.Diagnoses;
SELECT @b = SUM(SickLeaveDays) FROM dbo.FactVisits WHERE SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Сума днів лікарняного OLTP = DW', CAST(@a AS NVARCHAR(20)), CAST(@b AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

SELECT @a = COUNT(*) FROM dbo.FactVisits WHERE SourceSystem = N'OLTP' AND -1 IN (PatientKey, DoctorKey, DiseaseKey, AgeGroupKey, OutcomeKey);
INSERT INTO #Checks VALUES (N'B. Звірка', N'Факти візитів OLTP з невідомими ключами (-1)', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM dbo.FactPrescriptions WHERE SourceSystem = N'OLTP' AND -1 IN (PatientKey, DoctorKey, DiseaseKey, MedicationKey, AgeGroupKey);
INSERT INTO #Checks VALUES (N'B. Звірка', N'Факти рецептів OLTP з невідомими ключами (-1)', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

-- Агрегований факт узгоджений з детальним
SELECT @a = SUM(TotalVisitsCount) FROM dbo.FactDoctorMonthlySummary;
SELECT @b = SUM(VisitCount) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'B. Звірка', N'FactDoctorMonthlySummary.TotalVisits = SUM(FactVisits.VisitCount)', CAST(@b AS NVARCHAR(20)), CAST(@a AS NVARCHAR(20)), IIF(@a = @b, 1, 0));

SELECT @x = SUM(TotalRevenueUAH) FROM dbo.FactDoctorMonthlySummary;
SELECT @y = SUM(ConsultationCostUAH) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Дохід у місячному агрегаті = сумі фактів', CAST(@y AS NVARCHAR(30)), CAST(@x AS NVARCHAR(30)), IIF(@x = @y, 1, 0));

-- Конвертація валют і похідні колонки
SELECT @a = COUNT(*) FROM dbo.FactVisits f JOIN dbo.RefExchangeRate r ON r.YearNumber = f.DateKey / 10000
WHERE ABS(f.ConsultationCostEUR - CAST(f.ConsultationCostUAH / r.UAHperEUR AS DECIMAL(10,2))) > 0.01;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Помилки конвертації UAH -> EUR за курсом року', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM dbo.FactVisits f JOIN dbo.DimAgeGroup g ON g.AgeGroupKey = f.AgeGroupKey
WHERE f.AgeAtVisit NOT BETWEEN g.AgeFrom AND g.AgeTo;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Вікова група не відповідає віку на дату візиту', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM dbo.DimMedication WHERE MedicationKey <> -1 AND (ManufacturerCountry = N'Невідомо' OR ManufacturerCountry = N'');
INSERT INTO #Checks VALUES (N'B. Звірка', N'Препарати без визначеної країни виробника', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM etl.PackageExecutionLog WHERE ExecutionStatus = N'Success' AND LoadType = N'Full';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Успішне повне завантаження в журналі ETL', N'>= 1', CAST(@a AS NVARCHAR(20)), IIF(@a >= 1, 1, 0));

SELECT @a = COUNT(*) FROM etl.Watermarks WHERE LastLoadedValue <= '1900-01-01';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Watermarks не просунуті після завантаження', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));
GO

/* ---------------------------------------------------------------------
   C. ЦІЛІСНІСТЬ SCD TYPE 2
   --------------------------------------------------------------------- */
DECLARE @a INT;
SELECT @a = COUNT(*) FROM (SELECT PatientID_Source FROM dbo.DimPatient GROUP BY PatientID_Source HAVING SUM(CAST(IsCurrent AS INT)) <> 1) x;
INSERT INTO #Checks VALUES (N'C. SCD2', N'Пацієнти не з рівно однією поточною версією', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM (SELECT DoctorID_Source FROM dbo.DimDoctor GROUP BY DoctorID_Source HAVING SUM(CAST(IsCurrent AS INT)) <> 1) x;
INSERT INTO #Checks VALUES (N'C. SCD2', N'Лікарі не з рівно однією поточною версією', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM dbo.DimPatient a JOIN dbo.DimPatient b
    ON a.PatientID_Source = b.PatientID_Source AND a.PatientKey < b.PatientKey AND a.ValidFrom < b.ValidTo AND b.ValidFrom < a.ValidTo;
INSERT INTO #Checks VALUES (N'C. SCD2', N'Перекриття інтервалів дії версій пацієнтів', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));

SELECT @a = COUNT(*) FROM dbo.FactVisits f JOIN dbo.DimDate dt ON dt.DateKey = f.DateKey
JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey
WHERE f.DoctorKey <> -1 AND NOT (dt.FullDate >= CAST(d.ValidFrom AS DATE) AND dt.FullDate <= CAST(d.ValidTo AS DATE));
INSERT INTO #Checks VALUES (N'C. SCD2', N'Факти, прив''язані до версії лікаря поза її інтервалом', N'0', CAST(@a AS NVARCHAR(20)), IIF(@a = 0, 1, 0));
GO

/* ---------------------------------------------------------------------
   D. ІНКРЕМЕНТАЛЬНИЙ СЦЕНАРІЙ (усе відкочується)
   --------------------------------------------------------------------- */
DECLARE @Pat INT, @OldAddr NVARCHAR(250), @Doc INT, @OpenDiag BIGINT, @Med INT, @Dis INT;
DECLARE @NewVisit BIGINT, @NewDiag BIGINT, @Exec INT, @Msg NVARCHAR(4000);
DECLARE @ok1 BIT = 0, @ok2 BIT = 0, @ok3 BIT = 0, @ok4 BIT = 0, @ok5 BIT = 0, @ok6 BIT = 0, @ok7 BIT = 0, @ok8 BIT = 0;
DECLARE @Extracted INT, @Versions INT, @OldFactsOnOld INT, @NewFactOnNew INT;
-- Новий візит датується «через годину від зараз», тобто після моменту зміни атрибутів SCD2
DECLARE @VisitDT DATETIME2(0) = DATEADD(HOUR, 1, CAST(SYSDATETIME() AS DATETIME2(0)));
DECLARE @VisitDateKey INT = YEAR(@VisitDT) * 10000 + MONTH(@VisitDT) * 100 + DAY(@VisitDT);

-- Пацієнт з візитами, активний лікар-терапевт, незавершений випадок, безпечний препарат (парацетамол без алергії)
SELECT TOP (1) @Pat = p.PatientID, @OldAddr = p.AddressLine FROM PolyclinicOLTP.dbo.Patients p
WHERE EXISTS (SELECT 1 FROM PolyclinicOLTP.dbo.Visits v WHERE v.PatientID = p.PatientID) AND p.BirthDate < '2000-01-01' ORDER BY p.PatientID;
SELECT TOP (1) @Doc = d.DoctorID FROM PolyclinicOLTP.dbo.Doctors d WHERE d.IsActive = 1 AND d.SpecialtyID = 1 AND d.QualificationCategory <> N'Вища' ORDER BY d.DoctorID;
SELECT TOP (1) @OpenDiag = DiagnosisID FROM PolyclinicOLTP.dbo.Diagnoses WHERE TreatmentOutcome = N'В процесі' ORDER BY DiagnosisID;
SELECT @Dis = DiseaseID FROM PolyclinicOLTP.dbo.Diseases WHERE ICD10Code = 'J06.9';
SELECT TOP (1) @Med = m.MedicationID FROM PolyclinicOLTP.dbo.Medications m
WHERE m.ActiveSubstance LIKE N'Парацетамол%' AND NOT EXISTS (SELECT 1 FROM PolyclinicOLTP.dbo.PatientContraindications pc WHERE pc.PatientID = @Pat AND pc.MedicationID = m.MedicationID)
ORDER BY m.MedicationID;

BEGIN TRY
    BEGIN TRAN;

    -- 1) Зміни в OLTP (тригери автоматично оновлюють UpdatedAt)
    UPDATE PolyclinicOLTP.dbo.Patients SET AddressLine = N'м. Львів, вул. Тестова (смоук-тест SCD2), буд. 1' WHERE PatientID = @Pat;
    UPDATE PolyclinicOLTP.dbo.Doctors SET QualificationCategory = N'Вища' WHERE DoctorID = @Doc;
    EXEC PolyclinicOLTP.dbo.usp_CloseDiagnosisCase @DiagnosisID = @OpenDiag, @TreatmentOutcome = N'Одужання', @RecoveryDate = '2026-01-20';
    EXEC PolyclinicOLTP.dbo.usp_RegisterVisitAndDiagnosis
        @PatientID = @Pat, @DoctorID = @Doc, @VisitDateTime = @VisitDT, @VisitType = N'Первинний',
        @DurationMinutes = 30, @IsFreeNSZU = 0, @Complaints = N'Смоук-тест інкрементального ETL', @DiseaseID = @Dis,
        @Severity = N'Легка', @SickLeaveDays = 3, @NewVisitID = @NewVisit OUTPUT, @NewDiagnosisID = @NewDiag OUTPUT;
    EXEC PolyclinicOLTP.dbo.usp_PrescribeMedication @DiagnosisID = @NewDiag, @MedicationID = @Med,
        @DailyDosage = N'По 1 таблетці 3 рази на добу', @DurationDays = 5, @QuantityPackages = 1, @IsSubsidized = 0;

    -- 2) Інкрементальний ETL
    EXEC etl.usp_RunReferenceETL @LoadType = N'Incremental', @ExecutionID = @Exec OUTPUT;
    -- рядки фактів і пацієнтів, витягнуті інкрементально (довідники хвороб/ліків/лікарів порівнюються повністю)
    SELECT @Extracted = SUM(RowsRead) FROM etl.TaskLog
    WHERE ExecutionID = @Exec AND TaskName IN (N'DimPatient (SCD2)', N'FactVisits (MERGE)', N'FactPrescriptions (MERGE)');

    -- 3) Перевірки
    -- 3.1 Витягнуто лише змінені рядки
    IF @Extracted BETWEEN 4 AND 10 SET @ok1 = 1;    -- 1 пацієнт + 2 діагнози (новий і закритий) + 1 рецепт
    -- 3.2 SCD2 пацієнта: 2 версії, стара закрита, нова поточна
    SELECT @Versions = COUNT(*) FROM dbo.DimPatient WHERE PatientID_Source = @Pat;
    IF @Versions = 2 AND EXISTS (SELECT 1 FROM dbo.DimPatient WHERE PatientID_Source = @Pat AND IsCurrent = 0 AND AddressLine = @OldAddr AND ValidTo < '9999-12-31')
                     AND EXISTS (SELECT 1 FROM dbo.DimPatient WHERE PatientID_Source = @Pat AND IsCurrent = 1 AND AddressLine LIKE N'%Тестова%')
        SET @ok2 = 1;
    -- 3.3 Історичні факти лишились на старій версії, новий візит — на новій
    SELECT @OldFactsOnOld = COUNT(*) FROM dbo.FactVisits f JOIN dbo.DimPatient d ON d.PatientKey = f.PatientKey
    WHERE d.PatientID_Source = @Pat AND d.IsCurrent = 0;
    SELECT @NewFactOnNew = COUNT(*) FROM dbo.FactVisits f JOIN dbo.DimPatient d ON d.PatientKey = f.PatientKey
    WHERE d.PatientID_Source = @Pat AND d.IsCurrent = 1 AND f.DiagnosisID_Source = @NewDiag;
    IF @OldFactsOnOld > 0 AND @NewFactOnNew = 1 SET @ok3 = 1;
    -- 3.4 SCD2 лікаря: нова версія з категорією "Вища"
    IF (SELECT COUNT(*) FROM dbo.DimDoctor WHERE DoctorID_Source = @Doc) = 2
       AND EXISTS (SELECT 1 FROM dbo.DimDoctor WHERE DoctorID_Source = @Doc AND IsCurrent = 1 AND QualificationCategory = N'Вища')
        SET @ok4 = 1;
    -- 3.5 Закритий випадок оновився у факті (UPSERT), а не продублювався
    IF (SELECT COUNT(*) FROM dbo.FactVisits WHERE SourceSystem = N'OLTP' AND DiagnosisID_Source = @OpenDiag) = 1
       AND EXISTS (SELECT 1 FROM dbo.FactVisits f JOIN dbo.DimClinicalOutcome o ON o.OutcomeKey = f.OutcomeKey
                   WHERE f.DiagnosisID_Source = @OpenDiag AND o.TreatmentOutcome = N'Одужання' AND f.RecoveryDateKey = 20260120 AND f.UpdatedAt IS NOT NULL)
        SET @ok5 = 1;
    -- 3.6 Новий візит: вартість за ставкою терапевта (30 хв × 450 грн/год = 225.00) і рецепт завантажено
    IF EXISTS (SELECT 1 FROM dbo.FactVisits WHERE DiagnosisID_Source = @NewDiag AND ConsultationCostUAH = 225.00 AND DateKey = @VisitDateKey AND VisitCount = 1)
       AND EXISTS (SELECT 1 FROM dbo.FactPrescriptions fp JOIN PolyclinicOLTP.dbo.Prescriptions pr ON pr.PrescriptionID = fp.PrescriptionID_Source
                   WHERE pr.DiagnosisID = @NewDiag)
        SET @ok6 = 1;
    -- 3.7 Місячний агрегат за жовтень 2026 перераховано
    IF EXISTS (SELECT 1 FROM dbo.FactDoctorMonthlySummary s JOIN dbo.DimDoctor d ON d.DoctorKey = s.DoctorKey
               WHERE s.MonthKey = @VisitDateKey / 100 AND d.DoctorID_Source = @Doc AND s.TotalVisitsCount >= 1)
        SET @ok7 = 1;
    -- 3.8 Watermark візитів просунувся до часу змін
    IF (SELECT LastLoadedValue FROM etl.Watermarks WHERE TableName = 'Visits') >= DATEADD(MINUTE, -5, SYSDATETIME())
        SET @ok8 = 1;

    ROLLBACK;
END TRY
BEGIN CATCH
    SET @Msg = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES
 (N'D. Інкремент', N'Інкремент: витягнуто лише змінені рядки (пацієнт, діагнози, рецепт)', N'4..10', ISNULL(CAST(@Extracted AS NVARCHAR(20)), LEFT(@Msg, 60)), @ok1),
 (N'D. Інкремент', N'SCD2 пацієнта: стара версія закрита, нова поточна', N'2 версії', ISNULL(CAST(@Versions AS NVARCHAR(20)), N'—'), @ok2),
 (N'D. Інкремент', N'Історія на старій версії, новий візит — на новій', N'так', CONCAT(@OldFactsOnOld, N' / ', @NewFactOnNew), @ok3),
 (N'D. Інкремент', N'SCD2 лікаря: нова версія з категорією «Вища»', N'так', IIF(@ok4 = 1, N'так', N'ні'), @ok4),
 (N'D. Інкремент', N'Закритий випадок оновлено у факті (UPSERT без дублів)', N'так', IIF(@ok5 = 1, N'так', N'ні'), @ok5),
 (N'D. Інкремент', N'Новий візит (225.00 грн) і рецепт завантажено', N'так', IIF(@ok6 = 1, N'так', N'ні'), @ok6),
 (N'D. Інкремент', N'Місячний агрегат за поточний місяць перераховано', N'так', IIF(@ok7 = 1, N'так', N'ні'), @ok7),
 (N'D. Інкремент', N'Watermark візитів просунуто', N'так', IIF(@ok8 = 1, N'так', N'ні'), @ok8);

-- Перевірка, що відкат повернув усе як було
DECLARE @after INT = (SELECT COUNT(*) FROM dbo.DimPatient WHERE PatientID_Source = @Pat);
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed)
VALUES (N'D. Інкремент', N'Після ROLLBACK тестові зміни відсутні', N'1 версія', CAST(@after AS NVARCHAR(10)), IIF(@after = 1, 1, 0));
GO

/* ---------------------------------------------------------------------
   E. ПІДСУМОК
   --------------------------------------------------------------------- */
SELECT CheckID, CheckGroup, CheckName, Expected, Actual, Status FROM #Checks ORDER BY CheckID;

DECLARE @Failed INT = (SELECT COUNT(*) FROM #Checks WHERE Passed = 0), @Total INT = (SELECT COUNT(*) FROM #Checks);
DECLARE @Summary NVARCHAR(200) = N'СМОУК-ТЕСТ DW: ' + CAST(@Total - @Failed AS NVARCHAR(10)) + N' / ' + CAST(@Total AS NVARCHAR(10)) + N' перевірок пройдено.';
PRINT @Summary;
IF @Failed > 0
    RAISERROR(N'СМОУК-ТЕСТ DW: є непройдені перевірки (%d).', 16, 1, @Failed);
GO
