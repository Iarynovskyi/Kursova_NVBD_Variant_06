/* =====================================================================
   Файл: VERIFY_DATA.sql
   Опис: Верифікація згенерованих даних та смоук-тест (Етап 2.4 + Додаткові вимоги п.3)
     1. Кількість записів vs вимоги методички / варіанту №6
     2. Часовий діапазон (10 років), тренд і сезонність
     3. Якість та реалістичність даних (бізнес-логіка)
     4. Тестування обмежень цілісності (CHECK / FK / UNIQUE) та тригерів
     5. Тестування продуктивності запитів (вплив індексів)
     6. Підсумкова таблиця PASS / FAIL
   ===================================================================== */

USE PolyclinicOLTP;
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;

DROP TABLE IF EXISTS #Checks, #Perf;
CREATE TABLE #Checks (
    CheckID INT IDENTITY(1,1) PRIMARY KEY,
    CheckGroup NVARCHAR(40) NOT NULL,
    CheckName NVARCHAR(200) NOT NULL,
    Expected NVARCHAR(60) NOT NULL,
    Actual NVARCHAR(60) NULL,
    Status AS (CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END),
    Passed BIT NOT NULL
);
CREATE TABLE #Perf (TestName NVARCHAR(150) NOT NULL, DurationMs INT NOT NULL, RowsReturned INT NULL);
GO

/* ---------------------------------------------------------------------
   1. КІЛЬКІСТЬ ЗАПИСІВ У ВСІХ ТАБЛИЦЯХ
   --------------------------------------------------------------------- */
SELECT
    t.name AS TableName,
    SUM(p.rows) AS TotalRows
FROM sys.tables t
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
GROUP BY t.name
ORDER BY TotalRows DESC;

DECLARE @Patients INT = (SELECT COUNT(*) FROM dbo.Patients),
        @Visits INT = (SELECT COUNT(*) FROM dbo.Visits),
        @Diag INT = (SELECT COUNT(*) FROM dbo.Diagnoses),
        @Rx INT = (SELECT COUNT(*) FROM dbo.Prescriptions),
        @Meds INT = (SELECT COUNT(*) FROM dbo.Medications),
        @Ref INT = (SELECT COUNT(*) FROM dbo.Medications) + (SELECT COUNT(*) FROM dbo.Diseases) + (SELECT COUNT(*) FROM dbo.Doctors)
                 + (SELECT COUNT(*) FROM dbo.Departments) + (SELECT COUNT(*) FROM dbo.Specialties),
        @Years INT = (SELECT COUNT(DISTINCT YEAR(VisitDateTime)) FROM dbo.Visits),
        @MinY INT = (SELECT MIN(YEAR(VisitDateTime)) FROM dbo.Visits),
        @MaxY INT = (SELECT MAX(YEAR(VisitDateTime)) FROM dbo.Visits);

INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES
 (N'1. Обсяги', N'Пацієнтів (варіант 6: мін. 50 000)', N'>= 50 000', CAST(@Patients AS NVARCHAR(20)), IIF(@Patients >= 50000, 1, 0)),
 (N'1. Обсяги', N'Записів історій хвороб / Diagnoses (мін. 500 000)', N'>= 500 000', CAST(@Diag AS NVARCHAR(20)), IIF(@Diag >= 500000, 1, 0)),
 (N'1. Обсяги', N'Таблиця фактів Visits (мін. 500 000)', N'>= 500 000', CAST(@Visits AS NVARCHAR(20)), IIF(@Visits >= 500000, 1, 0)),
 (N'1. Обсяги', N'Таблиця фактів Prescriptions (мін. 500 000)', N'>= 500 000', CAST(@Rx AS NVARCHAR(20)), IIF(@Rx >= 500000, 1, 0)),
 (N'1. Обсяги', N'Довідник Medications (мін. 100 000 у довідниках)', N'>= 100 000', CAST(@Meds AS NVARCHAR(20)), IIF(@Meds >= 100000, 1, 0)),
 (N'1. Обсяги', N'Усього записів у довідникових таблицях', N'>= 100 000', CAST(@Ref AS NVARCHAR(20)), IIF(@Ref >= 100000, 1, 0)),
 (N'2. Період', N'Історія за 10 років (кількість календарних років)', N'10', CAST(@Years AS NVARCHAR(20)), IIF(@Years >= 10, 1, 0)),
 (N'2. Період', N'Діапазон років візитів', N'2016–2025', CAST(@MinY AS NVARCHAR(4)) + N'–' + CAST(@MaxY AS NVARCHAR(4)), IIF(@MinY = 2016 AND @MaxY = 2025, 1, 0));
GO

/* ---------------------------------------------------------------------
   2. ЧАСОВИЙ ДІАПАЗОН, ТРЕНД ТА СЕЗОННІСТЬ (скріншоти для звіту)
   --------------------------------------------------------------------- */
-- 2.1 Динаміка по роках: зростання бази пацієнтів, COVID-2020, частка НСЗУ
SELECT
    YEAR(v.VisitDateTime) AS VisitYear,
    COUNT(*) AS Visits,
    COUNT(DISTINCT v.PatientID) AS UniquePatients,
    CAST(100.0 * SUM(CAST(v.IsFreeNSZU AS INT)) / COUNT(*) AS DECIMAL(5,1)) AS FreeNSZU_Pct,
    SUM(CASE WHEN d.ICD10Code = 'U07.1' THEN 1 ELSE 0 END) AS Covid19Cases
FROM dbo.Visits v
JOIN dbo.Diagnoses dg ON dg.VisitID = v.VisitID AND dg.IsPrimary = 1
JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
GROUP BY YEAR(v.VisitDateTime)
ORDER BY VisitYear;

-- 2.2 Сезонність: респіраторні хвороби та травми по місяцях
SELECT
    MONTH(dg.DiagnosisDate) AS MonthNo,
    SUM(CASE WHEN d.ICD10Code LIKE 'J%' THEN 1 ELSE 0 END) AS Respiratory,
    SUM(CASE WHEN d.ICD10Code LIKE 'S%' OR d.ICD10Code LIKE 'T%' THEN 1 ELSE 0 END) AS Injuries,
    SUM(CASE WHEN d.ICD10Code IN ('J30.1', 'L50.0', 'H10.9') THEN 1 ELSE 0 END) AS Allergies,
    COUNT(*) AS AllDiagnoses
FROM dbo.Diagnoses dg
JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
GROUP BY MONTH(dg.DiagnosisDate)
ORDER BY MonthNo;

-- 2.3 Топ-10 захворювань
SELECT TOP (10) d.ICD10Code, d.DiseaseName, d.DiseaseCategory, COUNT(*) AS Cases
FROM dbo.Diagnoses dg JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
GROUP BY d.ICD10Code, d.DiseaseName, d.DiseaseCategory
ORDER BY Cases DESC;

-- 2.4 Розподіли категоріальних атрибутів
SELECT N'Тип візиту' AS Attribute, VisitType AS Value, COUNT(*) AS Cnt FROM dbo.Visits GROUP BY VisitType
UNION ALL
SELECT N'Результат лікування', TreatmentOutcome, COUNT(*) FROM dbo.Diagnoses GROUP BY TreatmentOutcome
UNION ALL
SELECT N'Тяжкість', Severity, COUNT(*) FROM dbo.Diagnoses GROUP BY Severity
UNION ALL
SELECT N'Стать пацієнта', Gender, COUNT(*) FROM dbo.Patients GROUP BY Gender
ORDER BY Attribute, Cnt DESC;

DECLARE @Jan INT = (SELECT COUNT(*) FROM dbo.Diagnoses dg JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID WHERE d.ICD10Code LIKE 'J%' AND MONTH(dg.DiagnosisDate) = 1),
        @Jul INT = (SELECT COUNT(*) FROM dbo.Diagnoses dg JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID WHERE d.ICD10Code LIKE 'J%' AND MONTH(dg.DiagnosisDate) = 7),
        @V2016 INT = (SELECT COUNT(*) FROM dbo.Visits WHERE YEAR(VisitDateTime) = 2016),
        @V2025 INT = (SELECT COUNT(*) FROM dbo.Visits WHERE YEAR(VisitDateTime) = 2025),
        @Sundays INT = (SELECT COUNT(*) FROM dbo.Visits WHERE DATEDIFF(DAY, '1900-01-01', VisitDateTime) % 7 = 6);

INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES
 (N'2. Період', N'Сезонність: респіраторні діагнози січень / липень', N'> 2.0', CAST(CAST(1.0 * @Jan / NULLIF(@Jul, 0) AS DECIMAL(6,2)) AS NVARCHAR(20)), IIF(1.0 * @Jan / NULLIF(@Jul, 0) > 2.0, 1, 0)),
 (N'2. Період', N'Тренд: візитів у 2025 / у 2016', N'> 1.10', CAST(CAST(1.0 * @V2025 / NULLIF(@V2016, 0) AS DECIMAL(6,2)) AS NVARCHAR(20)), IIF(1.0 * @V2025 / NULLIF(@V2016, 0) > 1.10, 1, 0)),
 (N'2. Період', N'Візити в неділю (поліклініка не працює)', N'0', CAST(@Sundays AS NVARCHAR(20)), IIF(@Sundays = 0, 1, 0));
GO

/* ---------------------------------------------------------------------
   3. ЯКІСТЬ ТА РЕАЛІСТИЧНІСТЬ ДАНИХ (бізнес-логіка)
   --------------------------------------------------------------------- */
DECLARE @c INT, @p DECIMAL(6,2);

-- 3.1 Стать: «жіночі» діагнози лише у жінок, «чоловічі» — лише у чоловіків; пацієнти гінеколога — жінки
SELECT @c = COUNT(*) FROM dbo.Diagnoses dg JOIN dbo.Visits v ON v.VisitID = dg.VisitID
JOIN dbo.Patients p ON p.PatientID = v.PatientID JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
WHERE (p.Gender = 'M' AND d.ICD10Code IN ('D25.9', 'C50.9', 'M81.0', 'N30.0', 'N76.0', 'N95.1', 'N92.0', 'N60.1', 'Z01.4'))
   OR (p.Gender = 'F' AND d.ICD10Code IN ('C61', 'N40', 'N41.1', 'K40.9'));
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Діагнози, що не відповідають статі пацієнта', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Visits v JOIN dbo.Doctors doc ON doc.DoctorID = v.DoctorID
JOIN dbo.Patients p ON p.PatientID = v.PatientID WHERE doc.SpecialtyID = 14 AND p.Gender = 'M';
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Пацієнти-чоловіки на прийомі в гінеколога', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

-- 3.2 Профіль: діагноз ставить або лікар первинної ланки, або профільний спеціаліст
SELECT @c = COUNT(*) FROM dbo.Diagnoses dg JOIN dbo.Visits v ON v.VisitID = dg.VisitID
JOIN dbo.Doctors doc ON doc.DoctorID = v.DoctorID JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
WHERE dg.IsPrimary = 1 AND doc.SpecialtyID NOT IN (1, 2) AND doc.SpecialtyID <> d.ProfileSpecialtyID;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Основні діагнози поза профілем лікаря', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

-- 3.3 Хронологія: візит не раніше народження/реєстрації пацієнта; лікар працює на дату візиту
SELECT @c = COUNT(*) FROM dbo.Visits v JOIN dbo.Patients p ON p.PatientID = v.PatientID
WHERE CAST(v.VisitDateTime AS DATE) < p.BirthDate OR CAST(v.VisitDateTime AS DATE) < p.RegistrationDate;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Візити до народження / реєстрації пацієнта', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Visits v JOIN dbo.Doctors doc ON doc.DoctorID = v.DoctorID
WHERE CAST(v.VisitDateTime AS DATE) < doc.HireDate OR CAST(v.VisitDateTime AS DATE) > ISNULL(doc.DismissalDate, '9999-12-31');
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Візити поза періодом роботи лікаря', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Diagnoses dg JOIN dbo.Visits v ON v.VisitID = dg.VisitID
WHERE dg.DiagnosisDate < CAST(v.VisitDateTime AS DATE);
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Діагнози з датою раніше за візит', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

-- 3.4 Діагнози: рівно один основний на візит; "В процесі" лише для недавніх випадків
SELECT @c = COUNT(*) FROM dbo.Visits v WHERE NOT EXISTS (SELECT 1 FROM dbo.Diagnoses dg WHERE dg.VisitID = v.VisitID AND dg.IsPrimary = 1);
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Візити без основного діагнозу', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Diagnoses
WHERE (TreatmentOutcome = N'В процесі' AND RecoveryDate IS NOT NULL) OR (TreatmentOutcome <> N'В процесі' AND RecoveryDate IS NULL);
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Порушення правила RecoveryDate ⇔ "В процесі"', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

DECLARE @MinOpen DATE = (SELECT MIN(DiagnosisDate) FROM dbo.Diagnoses WHERE TreatmentOutcome = N'В процесі');
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Найраніший незавершений випадок ("В процесі")', N'>= 2025-06-01', CONVERT(NVARCHAR(10), @MinOpen, 23), IIF(@MinOpen >= '2025-06-01', 1, 0));

-- 3.5 Різноманіття: у пацієнтів різні хвороби та різні лікарі (немає «зациклення»)
SELECT @p = 100.0 * SUM(CASE WHEN x.Dis >= 2 THEN 1 ELSE 0 END) / COUNT(*)
FROM (SELECT v.PatientID, COUNT(DISTINCT dg.DiseaseID) AS Dis FROM dbo.Visits v JOIN dbo.Diagnoses dg ON dg.VisitID = v.VisitID
      GROUP BY v.PatientID HAVING COUNT(DISTINCT v.VisitID) >= 3) x;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'% пацієнтів (3+ візити) з 2+ різними хворобами', N'> 50 %', CAST(@p AS NVARCHAR(20)), IIF(@p > 50, 1, 0));

SELECT @p = 100.0 * SUM(CASE WHEN x.Docs >= 2 THEN 1 ELSE 0 END) / COUNT(*)
FROM (SELECT PatientID, COUNT(DISTINCT DoctorID) AS Docs FROM dbo.Visits GROUP BY PatientID HAVING COUNT(*) >= 3) x;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'% пацієнтів (3+ візити), що відвідували 2+ лікарів', N'> 50 %', CAST(@p AS NVARCHAR(20)), IIF(@p > 50, 1, 0));

-- 3.6 Довідники: одна діюча речовина -> одна фармакологічна група; відділення відповідає спеціальності
SELECT @c = COUNT(*) FROM (SELECT ActiveSubstance FROM dbo.Medications GROUP BY ActiveSubstance HAVING COUNT(DISTINCT PharmacologicalGroup) > 1) x;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Діючі речовини з кількома фармгрупами', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Doctors WHERE (SpecialtyID = 3 AND DepartmentID <> 3) OR (SpecialtyID = 14 AND DepartmentID <> 13)
                                         OR (SpecialtyID = 7 AND DepartmentID <> 7) OR (SpecialtyID IN (1, 2) AND DepartmentID NOT IN (1, 2, 12));
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Лікарі у відділенні не за спеціальністю', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

-- 3.7 Реформи: COVID-19 лише з 03.2020; безкоштовні прийоми НСЗУ лише з 07.2018; "Доступні ліки" лише з 04.2017
SELECT @c = COUNT(*) FROM dbo.Diagnoses dg JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID WHERE d.ICD10Code = 'U07.1' AND dg.DiagnosisDate < '2020-03-01';
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Діагнози COVID-19 до березня 2020', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Visits WHERE IsFreeNSZU = 1 AND VisitDateTime < '2018-07-01';
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Безкоштовні прийоми НСЗУ до 07.2018', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

SELECT @c = COUNT(*) FROM dbo.Prescriptions WHERE IsSubsidized = 1 AND CreatedAt < '2017-04-01';
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Реімбурсовані рецепти до 04.2017', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

-- 3.8 Безпека призначень: жоден рецепт не порушує правило BR-1 (та сама логіка, що в тригері)
SELECT @c = COUNT(*)
FROM dbo.Prescriptions pr
JOIN dbo.Diagnoses cd ON cd.DiagnosisID = pr.DiagnosisID
JOIN dbo.Visits cv ON cv.VisitID = cd.VisitID
WHERE EXISTS (SELECT 1 FROM dbo.PatientContraindications pc WHERE pc.PatientID = cv.PatientID AND pc.MedicationID = pr.MedicationID)
   OR EXISTS (SELECT 1
              FROM dbo.Visits av
              JOIN dbo.Diagnoses ad ON ad.VisitID = av.VisitID
              JOIN dbo.Diseases dis ON dis.DiseaseID = ad.DiseaseID
              JOIN dbo.MedicationDiseaseContraindications mdc ON mdc.MedicationID = pr.MedicationID AND mdc.DiseaseID = ad.DiseaseID
              WHERE av.PatientID = cv.PatientID AND mdc.SeverityLevel = N'Абсолютне'
                AND (ad.DiagnosisID = cd.DiagnosisID OR dis.IsChronic = 1 OR ad.TreatmentOutcome = N'В процесі'));
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'3. Якість', N'Рецепти, що порушують алергії / абсолютні протипоказання', N'0', CAST(@c AS NVARCHAR(20)), IIF(@c = 0, 1, 0));

-- 3.9 Відсоток NULL у необов'язкових полях (інформативно)
SELECT
    CAST(100.0 * SUM(CASE WHEN TaxCode IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS TaxCodeNull_Pct,
    CAST(100.0 * SUM(CASE WHEN MiddleName IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS MiddleNameNull_Pct,
    CAST(100.0 * SUM(CASE WHEN BloodType IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS BloodTypeNull_Pct
FROM dbo.Patients;
GO

/* ---------------------------------------------------------------------
   4. ТЕСТУВАННЯ ОБМЕЖЕНЬ ЦІЛІСНОСТІ ТА ТРИГЕРІВ
      Кожен тест виконується у транзакції, яка відкочується (дані не змінюються).
      PASS = сервер відхилив некоректну операцію з очікуваною помилкою.
   --------------------------------------------------------------------- */
DECLARE @Err INT, @Msg NVARCHAR(4000);
DECLARE @P1 INT = (SELECT MIN(PatientID) FROM dbo.Patients);
DECLARE @D1 INT = (SELECT TOP 1 DoctorID FROM dbo.Doctors WHERE IsActive = 1 ORDER BY HireDate);

-- 4.1 CHECK: недопустима стать
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN; UPDATE dbo.Patients SET Gender = 'X' WHERE PatientID = @P1; ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Обмеження', N'CHECK CK_Patients_Gender (стать ''X'')', N'Помилка 547', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 547, 1, 0));

-- 4.2 FOREIGN KEY: візит неіснуючого пацієнта
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Visits (PatientID, DoctorID, VisitDateTime, VisitType, DurationMinutes, IsFreeNSZU)
    VALUES (-1, @D1, '2025-06-02 10:00', N'Первинний', 20, 0);
    ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Обмеження', N'FOREIGN KEY FK_Visits_Patients (PatientID = -1)', N'Помилка 547', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 547, 1, 0));

-- 4.3 UNIQUE: дублікат номера медичної картки
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Patients (MedicalCardNumber, LastName, FirstName, BirthDate, Gender, DistrictName, AddressLine, Phone, RegistrationDate)
    SELECT MedicalCardNumber, N'Тест', N'Тест', '1990-01-01', 'M', N'Галицький район', N'м. Львів', '+380670000000', '2020-01-01'
    FROM dbo.Patients WHERE PatientID = @P1;
    ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Обмеження', N'UNIQUE UQ_Patients_MedicalCardNumber (дублікат картки)', N'Помилка 2627', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 2627, 1, 0));

-- 4.4 Фільтрований UNIQUE-індекс: дублікат РНОКПП
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.Patients SET TaxCode = (SELECT TOP 1 TaxCode FROM dbo.Patients WHERE TaxCode IS NOT NULL ORDER BY PatientID)
    WHERE PatientID = (SELECT TOP 1 PatientID FROM dbo.Patients WHERE TaxCode IS NOT NULL ORDER BY PatientID DESC);
    ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Обмеження', N'UNIQUE INDEX UQ_Patients_TaxCode (дублікат РНОКПП)', N'Помилка 2601', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 2601, 1, 0));

-- 4.5 CHECK: завершений випадок без дати одужання
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    UPDATE TOP (1) dbo.Diagnoses SET RecoveryDate = NULL WHERE TreatmentOutcome = N'Одужання';
    ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Обмеження', N'CHECK CK_Diagnoses_OutcomeRecovery', N'Помилка 547', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 547, 1, 0));

-- 4.6 Фільтрований UNIQUE-індекс: другий основний діагноз у тому самому візиті
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Diagnoses (VisitID, DiseaseID, DiagnosisDate, IsPrimary, Severity, TreatmentOutcome, SickLeaveDays)
    SELECT TOP (1) dg.VisitID, (SELECT MIN(d.DiseaseID) FROM dbo.Diseases d WHERE d.DiseaseID NOT IN (SELECT x.DiseaseID FROM dbo.Diagnoses x WHERE x.VisitID = dg.VisitID)),
           dg.DiagnosisDate, 1, N'Легка', N'В процесі', 0
    FROM dbo.Diagnoses dg WHERE dg.IsPrimary = 1 ORDER BY dg.DiagnosisID;
    ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Обмеження', N'UNIQUE INDEX UX_Diagnoses_OnePrimaryPerVisit', N'Помилка 2601', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 2601, 1, 0));

-- 4.7 Тригер BR-1 (50001): рецепт на препарат, до якого в пацієнта алергія
DECLARE @AlP INT, @AlM INT, @AlDiag BIGINT;
SELECT TOP (1) @AlP = pc.PatientID, @AlM = pc.MedicationID
FROM dbo.PatientContraindications pc WHERE EXISTS (SELECT 1 FROM dbo.Visits v WHERE v.PatientID = pc.PatientID) ORDER BY pc.PatientContraID;
SELECT TOP (1) @AlDiag = dg.DiagnosisID FROM dbo.Diagnoses dg JOIN dbo.Visits v ON v.VisitID = dg.VisitID WHERE v.PatientID = @AlP ORDER BY dg.DiagnosisID;
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Prescriptions (DiagnosisID, MedicationID, DailyDosage, DurationDays, QuantityPackages, IsSubsidized)
    VALUES (@AlDiag, @AlM, N'Тестове дозування', 5, 1, 0);
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'TR_Prescriptions_CheckContraindications: алергія пацієнта', N'Помилка 50001', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50001, 1, 0));

-- 4.8 Тригер BR-1 (50002): бета-блокатор пацієнту з хронічною бронхіальною астмою (J45.0)
DECLARE @AsP INT, @AsDiag BIGINT, @BisoM INT;
SELECT TOP (1) @AsP = v.PatientID, @AsDiag = dg.DiagnosisID
FROM dbo.Diagnoses dg JOIN dbo.Visits v ON v.VisitID = dg.VisitID JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
WHERE d.ICD10Code = 'J45.0' ORDER BY dg.DiagnosisID;
SELECT TOP (1) @BisoM = m.MedicationID FROM dbo.Medications m
WHERE m.ActiveSubstance LIKE N'Бісопролол%'
  AND NOT EXISTS (SELECT 1 FROM dbo.PatientContraindications pc WHERE pc.PatientID = @AsP AND pc.MedicationID = m.MedicationID)
ORDER BY m.MedicationID;
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Prescriptions (DiagnosisID, MedicationID, DailyDosage, DurationDays, QuantityPackages, IsSubsidized)
    VALUES (@AsDiag, @BisoM, N'Тестове дозування', 30, 1, 0);
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'TR_Prescriptions_CheckContraindications: абсолютне протипоказання', N'Помилка 50002', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50002, 1, 0));

-- 4.9 Тригер BR-2 (50003): візит до дня народження пацієнта
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Visits (PatientID, DoctorID, VisitDateTime, VisitType, DurationMinutes, IsFreeNSZU)
    SELECT @P1, @D1, DATEADD(DAY, -1, CAST(BirthDate AS DATETIME2(0))), N'Первинний', 20, 0 FROM dbo.Patients WHERE PatientID = @P1;
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'TR_Visits_ValidateBusinessRules: візит до народження', N'Помилка 50003', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50003, 1, 0));

-- 4.10 Тригер BR-2 (50004): візит до дати прийому лікаря на роботу
DECLARE @NewDoc INT, @NewDocHire DATE;
SELECT TOP (1) @NewDoc = DoctorID, @NewDocHire = HireDate FROM dbo.Doctors WHERE HireDate >= '2016-01-01' AND IsActive = 1 ORDER BY HireDate DESC;
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Visits (PatientID, DoctorID, VisitDateTime, VisitType, DurationMinutes, IsFreeNSZU)
    SELECT TOP (1) p.PatientID, @NewDoc, DATEADD(HOUR, 10, CAST(DATEADD(DAY, -1, @NewDocHire) AS DATETIME2(0))), N'Первинний', 20, 0
    FROM dbo.Patients p WHERE p.BirthDate < '2000-01-01' ORDER BY p.PatientID;
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'TR_Visits_ValidateBusinessRules: візит до прийому лікаря на роботу', N'Помилка 50004', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50004, 1, 0));

-- 4.11 Тригер BR-2 (50005): запис до звільненого лікаря
DECLARE @OldDoc INT, @OldDocDism DATE;
SELECT TOP (1) @OldDoc = DoctorID, @OldDocDism = DismissalDate FROM dbo.Doctors WHERE IsActive = 0 ORDER BY DismissalDate;
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Visits (PatientID, DoctorID, VisitDateTime, VisitType, DurationMinutes, IsFreeNSZU)
    SELECT TOP (1) p.PatientID, @OldDoc, DATEADD(HOUR, 10, CAST(DATEADD(DAY, 7, @OldDocDism) AS DATETIME2(0))), N'Первинний', 20, 0
    FROM dbo.Patients p WHERE p.BirthDate < '2000-01-01' ORDER BY p.PatientID;
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'TR_Visits_ValidateBusinessRules: прийом у звільненого лікаря', N'Помилка 50005', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50005, 1, 0));

-- 4.12 Тригер BR-3 (50006): діагноз датований раніше за візит
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO dbo.Diagnoses (VisitID, DiseaseID, DiagnosisDate, IsPrimary, Severity, TreatmentOutcome, SickLeaveDays)
    SELECT TOP (1) v.VisitID,
           (SELECT MIN(d.DiseaseID) FROM dbo.Diseases d WHERE d.DiseaseID NOT IN (SELECT x.DiseaseID FROM dbo.Diagnoses x WHERE x.VisitID = v.VisitID)),
           DATEADD(DAY, -1, CAST(v.VisitDateTime AS DATE)), 0, N'Легка', N'В процесі', 0
    FROM dbo.Visits v ORDER BY v.VisitID DESC;
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'TR_Diagnoses_ValidateBusinessRules: діагноз раніше за візит', N'Помилка 50006', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50006, 1, 0));

-- 4.13 Процедура: заборона закрити випадок зі статусом "В процесі"
DECLARE @OpenDiag BIGINT = (SELECT TOP (1) DiagnosisID FROM dbo.Diagnoses WHERE TreatmentOutcome = N'В процесі' ORDER BY DiagnosisID);
SET @Err = NULL;
BEGIN TRY
    BEGIN TRAN;
    EXEC dbo.usp_CloseDiagnosisCase @DiagnosisID = @OpenDiag, @TreatmentOutcome = N'В процесі', @RecoveryDate = '2025-12-31';
    IF @@TRANCOUNT > 0 ROLLBACK;
END TRY BEGIN CATCH SET @Err = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'usp_CloseDiagnosisCase: валідація результату', N'Помилка 50010', ISNULL(N'Помилка ' + CAST(@Err AS NVARCHAR(10)), N'Немає помилки'), IIF(@Err = 50010, 1, 0));

-- 4.14 Позитивний сценарій: коректний візит + діагноз через процедуру і автооновлення UpdatedAt
DECLARE @NewVisit BIGINT, @NewDiag BIGINT, @Ok BIT = 0, @Before DATETIME2(0), @After DATETIME2(0);
DECLARE @Dis1 INT = (SELECT DiseaseID FROM dbo.Diseases WHERE ICD10Code = 'J06.9');
DECLARE @FamDoc INT = (SELECT TOP (1) DoctorID FROM dbo.Doctors WHERE IsActive = 1 AND SpecialtyID = 2 ORDER BY DoctorID);
BEGIN TRY
    BEGIN TRAN;
    EXEC dbo.usp_RegisterVisitAndDiagnosis
        @PatientID = @P1, @DoctorID = @FamDoc, @VisitDateTime = '2025-12-29 10:00', @VisitType = N'Первинний',
        @DurationMinutes = 20, @IsFreeNSZU = 1, @Complaints = N'Смоук-тест', @DiseaseID = @Dis1, @Severity = N'Легка',
        @SickLeaveDays = 0, @NewVisitID = @NewVisit OUTPUT, @NewDiagnosisID = @NewDiag OUTPUT;
    SELECT @Before = UpdatedAt FROM dbo.Visits WHERE VisitID = (SELECT MIN(VisitID) FROM dbo.Visits);
    UPDATE dbo.Visits SET Complaints = Complaints WHERE VisitID = (SELECT MIN(VisitID) FROM dbo.Visits);
    SELECT @After = UpdatedAt FROM dbo.Visits WHERE VisitID = (SELECT MIN(VisitID) FROM dbo.Visits);
    IF @NewVisit IS NOT NULL AND @NewDiag IS NOT NULL AND @After > @Before SET @Ok = 1;
    ROLLBACK;
END TRY BEGIN CATCH SET @Msg = ERROR_MESSAGE(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
INSERT INTO #Checks (CheckGroup, CheckName, Expected, Actual, Passed) VALUES (N'4. Тригери', N'Позитивний сценарій: реєстрація візиту + тригер UpdatedAt', N'Успіх', IIF(@Ok = 1, N'Успіх', ISNULL(LEFT(@Msg, 60), N'Помилка')), @Ok);
GO

/* ---------------------------------------------------------------------
   5. ТЕСТУВАННЯ ПРОДУКТИВНОСТІ ЗАПИТІВ НА ВЕЛИКИХ ОБСЯГАХ
   --------------------------------------------------------------------- */
DECLARE @t0 DATETIME2(7), @rows INT, @PatientID INT, @DoctorID INT;
SELECT TOP (1) @PatientID = PatientID FROM dbo.Visits GROUP BY PatientID ORDER BY COUNT(*) DESC;
SELECT TOP (1) @DoctorID = DoctorID FROM dbo.Visits GROUP BY DoctorID ORDER BY COUNT(*) DESC;

DROP TABLE IF EXISTS #Hist, #Work;
CREATE TABLE #Hist (VisitID BIGINT, VisitDateTime DATETIME2(0), VisitType NVARCHAR(30), DoctorFullName NVARCHAR(160), SpecialtyName NVARCHAR(100),
                    ICD10Code VARCHAR(10), DiseaseName NVARCHAR(200), IsPrimary BIT, Severity NVARCHAR(20), TreatmentOutcome NVARCHAR(30),
                    RecoveryDate DATE, SickLeaveDays SMALLINT, PrescriptionsCount INT, Complaints NVARCHAR(500));
CREATE TABLE #Work (VisitYear INT, VisitMonth INT, DepartmentName NVARCHAR(100), SpecialtyName NVARCHAR(100), HourlyRate DECIMAL(10,2),
                    DoctorID INT, DoctorFullName NVARCHAR(160), QualificationCategory NVARCHAR(30), TotalVisits INT, UniquePatients INT,
                    TotalMinutesSpent INT, TotalHoursSpent DECIMAL(10,2), CalculatedRevenue DECIMAL(18,2));

-- 5.1 Історія хвороби пацієнта (індекс IX_Visits_PatientID_Date)
SET @t0 = SYSDATETIME();
INSERT INTO #Hist EXEC dbo.usp_GetPatientMedicalHistory @PatientID = @PatientID;
SET @rows = @@ROWCOUNT;
INSERT INTO #Perf VALUES (N'Історія хвороби пацієнта (usp_GetPatientMedicalHistory)', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), @rows);

-- 5.2 Завантаженість лікарів за рік (агрегація ~60 000 візитів)
SET @t0 = SYSDATETIME();
INSERT INTO #Work EXEC dbo.usp_GetDoctorMonthlyWorkload @StartDate = '2024-01-01', @EndDate = '2024-12-31', @DepartmentID = NULL;
SET @rows = @@ROWCOUNT;
INSERT INTO #Perf VALUES (N'Завантаженість лікарів за 2024 рік (usp_GetDoctorMonthlyWorkload)', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), @rows);

-- 5.3 Статистика захворювань за 10 років (повна агрегація ~580 000 діагнозів)
SET @t0 = SYSDATETIME();
SELECT @rows = COUNT(*) FROM (
    SELECT YEAR(dg.DiagnosisDate) AS Y, d.DiseaseCategory, COUNT(*) AS Cases, AVG(CAST(dg.SickLeaveDays AS FLOAT)) AS AvgSick
    FROM dbo.Diagnoses dg JOIN dbo.Diseases d ON d.DiseaseID = dg.DiseaseID
    GROUP BY YEAR(dg.DiagnosisDate), d.DiseaseCategory) x;
INSERT INTO #Perf VALUES (N'Статистика захворювань: рік × категорія (повне сканування)', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), @rows);

-- 5.4 Вплив індексу: візити лікаря за квартал — з індексом vs примусове сканування кластерного індексу
SET @t0 = SYSDATETIME();
SELECT @rows = COUNT(*) FROM dbo.Visits WITH (INDEX(IX_Visits_DoctorID_Patient))
WHERE DoctorID = @DoctorID AND VisitDateTime >= '2024-01-01' AND VisitDateTime < '2024-04-01';
INSERT INTO #Perf VALUES (N'Візити лікаря за квартал — некластеризований індекс', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), @rows);

SET @t0 = SYSDATETIME();
SELECT @rows = COUNT(*) FROM dbo.Visits WITH (INDEX(1))
WHERE DoctorID = @DoctorID AND VisitDateTime >= '2024-01-01' AND VisitDateTime < '2024-04-01';
INSERT INTO #Perf VALUES (N'Візити лікаря за квартал — сканування таблиці (без індексу)', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), @rows);

-- 5.5 Статистика вводу-виводу для звіту (вивід у Messages)
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
EXEC dbo.usp_GetDoctorMonthlyWorkload @StartDate = '2025-12-01', @EndDate = '2025-12-31', @DepartmentID = 3;
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;

SELECT TestName, DurationMs, RowsReturned FROM #Perf;
GO

/* ---------------------------------------------------------------------
   6. ПІДСУМОК СМОУК-ТЕСТУ
   --------------------------------------------------------------------- */
SELECT CheckID, CheckGroup, CheckName, Expected, Actual, Status FROM #Checks ORDER BY CheckID;

DECLARE @Failed INT = (SELECT COUNT(*) FROM #Checks WHERE Passed = 0),
        @Total INT = (SELECT COUNT(*) FROM #Checks);
DECLARE @Summary NVARCHAR(200) = N'СМОУК-ТЕСТ: ' + CAST(@Total - @Failed AS NVARCHAR(10)) + N' / ' + CAST(@Total AS NVARCHAR(10)) + N' перевірок пройдено.';
PRINT @Summary;
IF @Failed > 0
    RAISERROR(N'СМОУК-ТЕСТ: є непройдені перевірки (%d). Див. таблицю результатів вище.', 16, 1, @Failed);
GO
