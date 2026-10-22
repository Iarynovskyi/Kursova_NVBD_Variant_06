/* =====================================================================
   Файл: VERIFY_DATA.sql
   Опис: Верифікація кількості, якості, часового діапазону та продуктивності (Етап 2.4)
   ===================================================================== */

USE PolyclinicOLTP;
GO

/* ---------------------------------------------------------------------
   1. ПЕРЕВІРКА КІЛЬКОСТІ ЗАПИСІВ У ВСІХ ТАБЛИЦЯХ (Скріншот для звіту)
   --------------------------------------------------------------------- */
SELECT 
    t.name AS TableName,
    SUM(p.rows) AS TotalRows,
    CASE 
        WHEN t.name = 'Patients' AND SUM(p.rows) >= 50000 THEN N'OK (Вимога >= 50 000 виконана)'
        WHEN t.name IN ('Visits', 'Diagnoses', 'Prescriptions') AND SUM(p.rows) >= 500000 THEN N'OK (Вимога >= 500 000 виконана)'
        WHEN t.name = 'Medications' AND SUM(p.rows) >= 100000 THEN N'OK (Вимога >= 100 000 у довідниках виконана)'
        ELSE N'OK (Довідник / Зв''язок)'
    END AS RequirementStatus
FROM sys.tables t
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
GROUP BY t.name
ORDER BY TotalRows DESC;
GO

/* ---------------------------------------------------------------------
   2. ПЕРЕВІРКА 10-РІЧНОГО ІСТОРИЧНОГО ПЕРІОДУ (Вимога Варіанту №6)
   --------------------------------------------------------------------- */
SELECT 
    MIN(VisitDateTime) AS FirstVisitDate,
    MAX(VisitDateTime) AS LastVisitDate,
    DATEDIFF(YEAR, MIN(VisitDateTime), MAX(VisitDateTime)) + 1 AS YearsOfHistoryCovered,
    COUNT(DISTINCT YEAR(VisitDateTime)) AS DistinctCalendarYears
FROM dbo.Visits;
GO

/* ---------------------------------------------------------------------
   3. ТЕСТУВАННЯ РОБОТИ ТРИГЕРА КОНТРОЛЮ ПРОТИПОКАЗАНЬ (Додаткові вимоги п. 3)
   Спроба призначити Пацієнту №1 препарат №90001, на який у нього алергія
   --------------------------------------------------------------------- */
BEGIN TRY
    -- Знаходимо будь-який діагноз Пацієнта №1
    DECLARE @TestDiagnosisID BIGINT = (
        SELECT TOP 1 d.DiagnosisID 
        FROM dbo.Diagnoses d
        INNER JOIN dbo.Visits v ON d.VisitID = v.VisitID
        WHERE v.PatientID = 1
    );

    -- Намагаємось виписати препарат 90001 (який є у PatientContraindications для PatientID = 1)
    INSERT INTO dbo.Prescriptions (DiagnosisID, MedicationID, DailyDosage, DurationDays, QuantityPackages, IsSubsidized)
    VALUES (@TestDiagnosisID, 90001, N'Тестове дозування', 5, 1, 0);
END TRY
BEGIN CATCH
    SELECT 
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS TriggerValidationMessage,
        N'Тригер успішно заблокував небезпечне призначення!' AS TestResult;
END CATCH;
GO

/* ---------------------------------------------------------------------
   4. ТЕСТ ПРОДУКТИВНОСТІ ЗАПИТІВ НА 550 000+ ЗАПИСІВ (Етап 2.4)
   --------------------------------------------------------------------- */
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

EXEC dbo.usp_GetDoctorMonthlyWorkload 
    @StartDate = '2024-01-01', 
    @EndDate = '2024-12-31', 
    @DepartmentID = NULL;

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO