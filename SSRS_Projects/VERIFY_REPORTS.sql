/* =====================================================================
   Файл: VERIFY_REPORTS.sql
   Опис: Тестування параметризації та даних звітів SSRS (Етап 5, «Тестування параметризації звітів»)
     A. Спільні набори даних (.rsd) — списки параметрів: кількість значень = сховище,
        значення за замовчуванням присутні у списках, каскад і пошук
     B. Дані звітів при параметрах за замовчуванням / тестових значеннях = сховище PolyclinicDW
     C. Безпека параметрів: STRTOMEMBER(..., CONSTRAINED) відхиляє некоректний член,
        межі діапазону дат (2016–2026) існують у вимірі Дата
     D. Час виконання запитів звітів
     E. Підсумок PASS / FAIL (RAISERROR при помилках)
   Запити MDX — ті самі, що в наборах даних звітів (SSRS_Projects/Polyclinic_Reports), з підставленими
   значеннями параметрів.
   Передумова: куб Polyclinic_OLAP оброблено; linked server SSAS_POLYCLINIC створено скриптом
               SSAS_Projects/VERIFY_CUBE.sql. Підключення SSMS — Windows-автентифікація
               (linked server передає обліковий запис користувача в Analysis Services).
   ===================================================================== */
USE PolyclinicDW;
SET NOCOUNT ON;
GO
DROP TABLE IF EXISTS #Checks, #P, #V, #Perf;
CREATE TABLE #Checks (
    CheckID INT IDENTITY(1,1) PRIMARY KEY, CheckGroup NVARCHAR(40) NOT NULL, CheckName NVARCHAR(220) NOT NULL,
    Expected NVARCHAR(80) NOT NULL, Actual NVARCHAR(80) NULL, Passed BIT NOT NULL,
    Status AS (CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END));
CREATE TABLE #P (Caption NVARCHAR(400) NULL, ParamValue NVARCHAR(400) NULL, ParamCaption NVARCHAR(400) NULL);  -- рядок списку параметра
CREATE TABLE #V (v FLOAT NULL);                                                                                  -- одна комірка MDX
CREATE TABLE #Perf (TestName NVARCHAR(200) NOT NULL, DurationMs INT NOT NULL);
GO

/* ---------------------------------------------------------------------
   A. СПІЛЬНІ НАБОРИ ДАНИХ (списки параметрів)
   --------------------------------------------------------------------- */
DECLARE @n INT, @dw INT, @t DATETIME2(3), @has INT;

-- A1. DS_Years (dropdown «Рік», звіти «Завантаженість лікарів», «Аналіз ефективності лікування»)
DELETE #P; SET @t = SYSDATETIME();
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Дата].[Календар].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Дата].[Календар].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
ORDER(NONEMPTY([Дата].[Календар].[Рік].MEMBERS, [Measures].[Кількість візитів]), [Дата].[Календар].CURRENTMEMBER.MEMBERVALUE, BDESC) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'DS_Years', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @n = COUNT(*), @has = SUM(IIF(ParamValue = N'[Дата].[Календар].[Рік].&[2025]', 1, 0)) FROM #P;
SELECT @dw = COUNT(DISTINCT d.YearNumber) FROM dbo.FactVisits f JOIN dbo.DimDate d ON d.DateKey = f.DateKey;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_Years: кількість років = роки з візитами у сховищі', CAST(@dw AS NVARCHAR(10)), CAST(@n AS NVARCHAR(10)), IIF(@n = @dw, 1, 0));
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_Years: значення за замовчуванням [Рік].&[2025] є у списку', N'1', CAST(@has AS NVARCHAR(10)), IIF(@has = 1, 1, 0));
SELECT @n = COUNT(*) FROM #P WHERE ParamValue IS NULL OR ParamCaption IS NULL;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_Years: немає порожніх Value / Label (мапінг полів .rsd)', N'0', CAST(@n AS NVARCHAR(10)), IIF(@n = 0, 1, 0));

-- A2. DS_Departments (dropdown «Відділення» — перший рівень каскаду, звіт «Лікарі та їх пацієнти»)
DELETE #P; SET @t = SYSDATETIME();
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Лікар].[Відділення].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Лікар].[Відділення].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
NONEMPTY([Лікар].[Відділення].[Відділення].MEMBERS, [Measures].[Кількість діагнозів]) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'DS_Departments', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @n = COUNT(*), @has = SUM(IIF(ParamValue = N'[Лікар].[Відділення].&[Кардіологічне відділення]', 1, 0)) FROM #P;
SELECT @dw = COUNT(DISTINCT d.DepartmentName) FROM dbo.FactVisits f JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_Departments: кількість відділень = сховище', CAST(@dw AS NVARCHAR(10)), CAST(@n AS NVARCHAR(10)), IIF(@n = @dw, 1, 0));
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_Departments: значення за замовчуванням (Кардіологічне відділення) є у списку', N'1', CAST(@has AS NVARCHAR(10)), IIF(@has = 1, 1, 0));

-- A3. DS_Specialties(@Department) — другий рівень каскаду; @Department = значення за замовчуванням
DELETE #P; SET @t = SYSDATETIME();
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Лікар].[Спеціальність].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Лікар].[Спеціальність].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
NONEMPTY(EXISTS([Лікар].[Спеціальність].[Спеціальність].MEMBERS, STRTOMEMBER("[Лікар].[Відділення].&[Кардіологічне відділення]", CONSTRAINED)), [Measures].[Кількість діагнозів]) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'DS_Specialties (каскад)', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @n = COUNT(*) FROM #P;
SELECT @dw = COUNT(DISTINCT d.SpecialtyName) FROM dbo.FactVisits f JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey
WHERE d.DepartmentName = N'Кардіологічне відділення';
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'Каскад: спеціальності Кардіологічного відділення = сховище', CAST(@dw AS NVARCHAR(10)), CAST(@n AS NVARCHAR(10)), IIF(@n = @dw AND @n > 0, 1, 0));

-- A4. DS_Doctors(@Specialties) — третій рівень каскаду; multi-value: усі спеціальності з A3 («Select All»)
DECLARE @set NVARCHAR(MAX), @mdx NVARCHAR(MAX);
SELECT @set = N'{' + STRING_AGG(CAST(ParamValue AS NVARCHAR(MAX)), N',') + N'}' FROM #P;
SET @mdx = N'WITH MEMBER [Measures].[ParamValue] AS [Лікар].[Лікар].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Лікар].[Лікар].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
NONEMPTY(EXISTS([Лікар].[Лікар].[Лікар].MEMBERS, STRTOSET("' + @set + N'", CONSTRAINED)), [Measures].[Кількість діагнозів]) ON ROWS
FROM [Polyclinic DW]';
DELETE #P; SET @t = SYSDATETIME();
INSERT INTO #P EXEC (@mdx) AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'DS_Doctors (каскад, multi-value)', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @n = COUNT(*) FROM #P;
SELECT @dw = COUNT(DISTINCT d.DoctorID_Source) FROM dbo.DimDoctor d
WHERE d.DepartmentName = N'Кардіологічне відділення'
  AND EXISTS (SELECT 1 FROM dbo.FactVisits f JOIN dbo.DimDoctor d2 ON d2.DoctorKey = f.DoctorKey WHERE d2.DoctorID_Source = d.DoctorID_Source);
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'Каскад: лікарі вибраних спеціальностей кардіології = сховище', CAST(@dw AS NVARCHAR(10)), CAST(@n AS NVARCHAR(10)), IIF(@n = @dw AND @n > 0, 1, 0));

-- A5. DS_AgeGroups (multi-select «Вікові групи», звіт «Реєстр пацієнтів»)
DELETE #P;
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Вікова група].[Вікова група].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Вікова група].[Вікова група].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
NONEMPTY([Вікова група].[Вікова група].[Вікова група].MEMBERS, [Measures].[Кількість діагнозів]) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*) FROM #P;
SELECT @dw = COUNT(DISTINCT AgeGroupKey) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_AgeGroups: кількість вікових груп = сховище', CAST(@dw AS NVARCHAR(10)), CAST(@n AS NVARCHAR(10)), IIF(@n = @dw, 1, 0));

-- A6. DS_ICD10Chapters (multi-select «Розділи МКХ-10», звіт «Статистика захворювань»)
DELETE #P;
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Хвороба].[Розділ МКХ-10].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Хвороба].[Розділ МКХ-10].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
NONEMPTY([Хвороба].[Розділ МКХ-10].[Розділ МКХ-10].MEMBERS, [Measures].[Кількість діагнозів]) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*), @has = SUM(IIF(ParamValue LIKE N'[[]Хвороба].[[]Розділ МКХ-10].&%', 1, 0)) FROM #P;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'DS_ICD10Chapters: розділи МКХ-10 з діагнозами, коректні унікальні імена', N'> 0, усі валідні', CAST(@n AS NVARCHAR(10)) + N' / ' + CAST(@has AS NVARCHAR(10)), IIF(@n > 0 AND @n = @has, 1, 0));

-- A7–A8. DS_PatientSearch(@Search) — пошук пацієнта (каскад «пошук → пацієнт», звіт «Історія хвороби»)
DELETE #P;
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Пацієнт].[Пацієнт].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Пацієнт].[Пацієнт].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
HEAD(FILTER([Пацієнт].[Пацієнт].[Пацієнт].MEMBERS,
            INSTR(1, UCASE([Пацієнт].[Пацієнт].CURRENTMEMBER.MEMBER_CAPTION), UCASE("mc-0000012")) > 0), 200) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*), @has = SUM(IIF(ParamValue = N'[Пацієнт].[Пацієнт].&[12]', 1, 0)) FROM #P;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'Пошук «mc-0000012» (без урахування регістру) знаходить рівно одного пацієнта &[12]', N'1 / 1', CAST(@n AS NVARCHAR(10)) + N' / ' + CAST(@has AS NVARCHAR(10)), IIF(@n = 1 AND @has = 1, 1, 0));

DELETE #P;
INSERT INTO #P EXEC (N'WITH MEMBER [Measures].[ParamValue] AS [Пацієнт].[Пацієнт].CURRENTMEMBER.UNIQUENAME
MEMBER [Measures].[ParamCaption] AS [Пацієнт].[Пацієнт].CURRENTMEMBER.MEMBER_CAPTION
SELECT { [Measures].[ParamValue], [Measures].[ParamCaption] } ON COLUMNS,
HEAD(FILTER([Пацієнт].[Пацієнт].[Пацієнт].MEMBERS,
            INSTR(1, UCASE([Пацієнт].[Пацієнт].CURRENTMEMBER.MEMBER_CAPTION), UCASE("")) > 0), 200) ON ROWS
FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*) FROM #P;
INSERT INTO #Checks VALUES (N'A. Списки параметрів', N'Порожній пошук (AllowBlank) повертає перші 200 пацієнтів', N'200', CAST(@n AS NVARCHAR(10)), IIF(@n = 200, 1, 0));
GO

/* ---------------------------------------------------------------------
   B. ДАНІ ЗВІТІВ = СХОВИЩЕ
   --------------------------------------------------------------------- */
DECLARE @cube FLOAT, @dw DECIMAL(18,4), @t DATETIME2(3);

-- B1–B2. «Лікарі та їх пацієнти»: Кардіологічне відділення, 01.01.2025–30.06.2025 (параметри за замовчуванням)
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість візитів] } ON COLUMNS
FROM ( SELECT { [Дата].[Календар].[День].&[20250101] : [Дата].[Календар].[День].&[20250630] } ON COLUMNS FROM [Polyclinic DW] )
WHERE ( [Лікар].[Відділення].&[Кардіологічне відділення] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Лікарі та їх пацієнти — візити відділення за період', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @cube = v FROM #V;
SELECT @dw = SUM(f.VisitCount) FROM dbo.FactVisits f JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey
WHERE d.DepartmentName = N'Кардіологічне відділення' AND f.DateKey BETWEEN 20250101 AND 20250630;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Лікарі та їх пацієнти: візити кардіології за 01–06.2025', CAST(CAST(@dw AS BIGINT) AS NVARCHAR(30)), CAST(CAST(@cube AS BIGINT) AS NVARCHAR(30)), IIF(ROUND(@cube, 0) = @dw, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'SELECT { [Measures].[Вартість консультацій у грн] } ON COLUMNS
FROM ( SELECT { [Дата].[Календар].[День].&[20250101] : [Дата].[Календар].[День].&[20250630] } ON COLUMNS FROM [Polyclinic DW] )
WHERE ( [Лікар].[Відділення].&[Кардіологічне відділення] )') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @dw = SUM(f.ConsultationCostUAH) FROM dbo.FactVisits f JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey
WHERE d.DepartmentName = N'Кардіологічне відділення' AND f.DateKey BETWEEN 20250101 AND 20250630;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Лікарі та їх пацієнти: вартість консультацій кардіології за 01–06.2025, грн', CAST(CAST(@dw AS DECIMAL(18,2)) AS NVARCHAR(30)), CAST(CAST(ROUND(@cube, 2) AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ABS(@cube - @dw) < 0.01, 1, 0));

-- B3–B4. «Історія хвороби пацієнта»: пацієнт MC-0000012 (&[12]), увесь період
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість діагнозів] } ON COLUMNS FROM [Polyclinic DW] WHERE ( [Пацієнт].[Пацієнт].&[12] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Історія хвороби — діагнози пацієнта', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @cube = v FROM #V;
SELECT @dw = COUNT(*) FROM dbo.FactVisits f JOIN dbo.DimPatient p ON p.PatientKey = f.PatientKey WHERE p.PatientID_Source = 12;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Історія хвороби: діагнозів пацієнта MC-0000012', CAST(CAST(@dw AS INT) AS NVARCHAR(30)), CAST(CAST(@cube AS INT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість рецептів] } ON COLUMNS FROM [Polyclinic DW] WHERE ( [Пацієнт].[Пацієнт].&[12] )') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @dw = SUM(r.PrescriptionCount) FROM dbo.FactPrescriptions r JOIN dbo.DimPatient p ON p.PatientKey = r.PatientKey WHERE p.PatientID_Source = 12;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Історія хвороби: колонка «Рецепти» — усього рецептів пацієнта MC-0000012', CAST(CAST(@dw AS INT) AS NVARCHAR(30)), CAST(CAST(@cube AS INT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

-- B5. «Рецепти діагнозу» (підзвіт, параметри за замовчуванням): &[12], 12.09.2017, хвороба &[5]
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість рецептів] } ON COLUMNS FROM [Polyclinic DW]
WHERE ( [Пацієнт].[Пацієнт].&[12], [Дата].[Дата].&[20170912], [Хвороба].[Хвороба].&[5] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Рецепти діагнозу (підзвіт)', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @cube = v FROM #V;
SELECT @dw = SUM(r.PrescriptionCount) FROM dbo.FactPrescriptions r
JOIN dbo.DimPatient p ON p.PatientKey = r.PatientKey
WHERE p.PatientID_Source = 12 AND r.DateKey = 20170912 AND r.DiseaseKey = 5;      -- ключ атрибута [Хвороба] = DiseaseKey
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Рецепти діагнозу: рецептів за діагнозом (&[5]) візиту 12.09.2017 (очікувано 3)', CAST(CAST(@dw AS INT) AS NVARCHAR(30)), CAST(CAST(@cube AS INT) AS NVARCHAR(30)), IIF(@cube = @dw AND @dw = 3, 1, 0));

-- B6–B7. «Завантаженість лікарів по місяцях»: 2025 рік; Boolean «Лише працюючі лікарі»
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'SELECT { [Measures].[Візитів за місяць] } ON COLUMNS FROM [Polyclinic DW] WHERE ( [Дата].[Календар].[Рік].&[2025] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Завантаженість лікарів — візити за рік (ROLAP)', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @cube = v FROM #V;
SELECT @dw = SUM(TotalVisitsCount) FROM dbo.FactDoctorMonthlySummary WHERE MonthKey BETWEEN 202501 AND 202512;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Завантаженість: візитів за 2025 рік (усі лікарі) = FactDoctorMonthlySummary', CAST(CAST(@dw AS BIGINT) AS NVARCHAR(30)), CAST(CAST(@cube AS BIGINT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'SELECT { [Measures].[Візитів за місяць] } ON COLUMNS
FROM ( SELECT {[Лікар].[Статус].&[Працює]} ON COLUMNS FROM [Polyclinic DW] ) WHERE ( [Дата].[Календар].[Рік].&[2025] )') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @dw = SUM(s.TotalVisitsCount) FROM dbo.FactDoctorMonthlySummary s JOIN dbo.DimDoctor d ON d.DoctorKey = s.DoctorKey
WHERE s.MonthKey BETWEEN 202501 AND 202512 AND d.IsActive = 1;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Завантаженість: Boolean «Лише працюючі лікарі» = True', CAST(CAST(@dw AS BIGINT) AS NVARCHAR(30)), CAST(CAST(@cube AS BIGINT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

-- B8–B9. «Аналіз ефективності лікування»: KPI за 2025 рік
DECLARE @kpi FLOAT, @status FLOAT;
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[KPI Значення] AS KPIValue("Ефективність лікування")
SELECT { [Measures].[KPI Значення] } ON COLUMNS FROM [Polyclinic DW] WHERE ( [Дата].[Календар].[Рік].&[2025] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Аналіз ефективності — KPI', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @kpi = v FROM #V;
SELECT @dw = 1.0 * SUM(f.IsRecoveredFlag) / NULLIF(SUM(IIF(f.RecoveryDateKey <> 19000101, 1, 0)), 0)
FROM dbo.FactVisits f WHERE f.DateKey BETWEEN 20250101 AND 20251231;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Ефективність лікування: KPI 2025 = одужання / завершені випадки у сховищі', CAST(CAST(@dw AS DECIMAL(9,4)) AS NVARCHAR(30)), CAST(CAST(@kpi AS DECIMAL(9,4)) AS NVARCHAR(30)), IIF(ABS(@kpi - @dw) < 0.0001, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[KPI Статус] AS KPIStatus("Ефективність лікування")
SELECT { [Measures].[KPI Статус] } ON COLUMNS FROM [Polyclinic DW] WHERE ( [Дата].[Календар].[Рік].&[2025] )') AT SSAS_POLYCLINIC;
SELECT @status = v FROM #V;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Ефективність лікування: статус KPI узгоджений з порогами (≥70 % → 1, 63–70 % → 0, інакше −1)',
    CAST(CASE WHEN @kpi >= 0.70 THEN 1 WHEN @kpi >= 0.63 THEN 0 ELSE -1 END AS NVARCHAR(10)), CAST(CAST(@status AS INT) AS NVARCHAR(10)),
    IIF(@status = CASE WHEN @kpi >= 0.70 THEN 1 WHEN @kpi >= 0.63 THEN 0 ELSE -1 END, 1, 0));

-- B10–B11. «Статистика захворювань»: 2025 рік, усі розділи; Boolean «Враховувати архів Філії №2»
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість діагнозів] } ON COLUMNS
FROM ( SELECT { [Дата].[Календар].[День].&[20250101] : [Дата].[Календар].[День].&[20251231] } ON COLUMNS FROM [Polyclinic DW] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Статистика захворювань — діагнози за період', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @cube = v FROM #V;
SELECT @dw = COUNT(*) FROM dbo.FactVisits WHERE DateKey BETWEEN 20250101 AND 20251231;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Статистика захворювань: діагнозів за 2025 рік (з архівом)', CAST(CAST(@dw AS BIGINT) AS NVARCHAR(30)), CAST(CAST(@cube AS BIGINT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість діагнозів] } ON COLUMNS
FROM ( SELECT ( { [Дата].[Календар].[День].&[20250101] : [Дата].[Календар].[День].&[20251231] }, {[Джерело даних].[Джерело даних].&[OLTP]} ) ON COLUMNS FROM [Polyclinic DW] )') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @dw = COUNT(*) FROM dbo.FactVisits WHERE DateKey BETWEEN 20250101 AND 20251231 AND SourceSystem = N'OLTP';
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Статистика захворювань: Boolean «Архів Філії №2» = False (лише основна система)', CAST(CAST(@dw AS BIGINT) AS NVARCHAR(30)), CAST(CAST(@cube AS BIGINT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

-- B12–B13. «Реєстр пацієнтів»: грудень 2025, усі вікові групи; пошук за № картки
DELETE #V; SET @t = SYSDATETIME();
INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[N] AS COUNT(NONEMPTY([Пацієнт].[Пацієнт].[Пацієнт].MEMBERS, [Measures].[Кількість візитів]))
SELECT { [Measures].[N] } ON COLUMNS
FROM ( SELECT { [Дата].[Календар].[День].&[20251201] : [Дата].[Календар].[День].&[20251231] } ON COLUMNS FROM [Polyclinic DW] )') AT SSAS_POLYCLINIC;
INSERT INTO #Perf VALUES (N'Реєстр пацієнтів — пацієнти за місяць', DATEDIFF(MILLISECOND, @t, SYSDATETIME()));
SELECT @cube = v FROM #V;
SELECT @dw = COUNT(DISTINCT p.PatientID_Source) FROM dbo.FactVisits f JOIN dbo.DimPatient p ON p.PatientKey = f.PatientKey
WHERE f.DateKey BETWEEN 20251201 AND 20251231;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Реєстр пацієнтів: пацієнтів з візитами у грудні 2025', CAST(CAST(@dw AS INT) AS NVARCHAR(30)), CAST(CAST(@cube AS INT) AS NVARCHAR(30)), IIF(@cube = @dw, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[N] AS COUNT(FILTER(NONEMPTY([Пацієнт].[Пацієнт].[Пацієнт].MEMBERS, [Measures].[Кількість візитів]),
    INSTR(1, UCASE([Пацієнт].[Пацієнт].CURRENTMEMBER.MEMBER_CAPTION), UCASE("MC-0014331")) > 0))
SELECT { [Measures].[N] } ON COLUMNS
FROM ( SELECT { [Дата].[Календар].[День].&[20251201] : [Дата].[Календар].[День].&[20251231] } ON COLUMNS FROM [Polyclinic DW] )') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
INSERT INTO #Checks VALUES (N'B. Дані звітів', N'Реєстр пацієнтів: пошук «MC-0014331» за грудень 2025 знаходить одного пацієнта', N'1', CAST(CAST(@cube AS INT) AS NVARCHAR(30)), IIF(@cube = 1, 1, 0));
GO

/* ---------------------------------------------------------------------
   C. БЕЗПЕКА ТА МЕЖІ ПАРАМЕТРІВ
   --------------------------------------------------------------------- */
DECLARE @err NVARCHAR(400) = NULL, @cube FLOAT;
BEGIN TRY
    DELETE #V;
    INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість візитів] } ON COLUMNS FROM [Polyclinic DW]
    WHERE ( STRTOMEMBER("[Лікар].[Відділення].&[Неіснуюче відділення]", CONSTRAINED) )') AT SSAS_POLYCLINIC;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH;
INSERT INTO #Checks VALUES (N'C. Безпека параметрів', N'STRTOMEMBER(..., CONSTRAINED): значення, якого немає в кубі, відхиляється помилкою', N'Помилка', IIF(@err IS NULL, N'Немає помилки', N'Помилка'), IIF(@err IS NOT NULL, 1, 0));

SET @err = NULL;
BEGIN TRY
    DELETE #V;
    INSERT INTO #V EXEC (N'SELECT { [Measures].[Кількість візитів] } ON COLUMNS FROM [Polyclinic DW]
    WHERE ( STRTOSET("{[Лікар].[Відділення].Members} * {[Пацієнт].[Пацієнт].Members}", CONSTRAINED) )') AT SSAS_POLYCLINIC;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH;
INSERT INTO #Checks VALUES (N'C. Безпека параметрів', N'STRTOSET(..., CONSTRAINED): довільний MDX-вираз замість списку членів відхиляється', N'Помилка', IIF(@err IS NULL, N'Немає помилки', N'Помилка'), IIF(@err IS NOT NULL, 1, 0));

DELETE #V;
INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[N] AS COUNT({ [Дата].[Календар].[День].&[20160101], [Дата].[Календар].[День].&[20261231] })
SELECT { [Measures].[N] } ON COLUMNS FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
INSERT INTO #Checks VALUES (N'C. Безпека параметрів', N'Межі діапазону дат звітів (01.01.2016 і 31.12.2026, Code.CheckRange) існують у вимірі Дата', N'2', CAST(CAST(@cube AS INT) AS NVARCHAR(10)), IIF(@cube = 2, 1, 0));
GO

/* ---------------------------------------------------------------------
   D–E. ПРОДУКТИВНІСТЬ І ПІДСУМОК
   --------------------------------------------------------------------- */
SELECT TestName AS [Запит звіту], DurationMs AS [Тривалість, мс] FROM #Perf ORDER BY DurationMs DESC;

SELECT CheckID, CheckGroup, CheckName, Expected, Actual, Status FROM #Checks ORDER BY CheckID;

DECLARE @total INT = (SELECT COUNT(*) FROM #Checks), @failed INT = (SELECT COUNT(*) FROM #Checks WHERE Passed = 0);
SELECT @total AS [Перевірок], @total - @failed AS [PASS], @failed AS [FAIL];
IF @failed > 0
    RAISERROR(N'VERIFY_REPORTS: %d з %d перевірок не пройдено.', 16, 1, @failed, @total);
ELSE
    PRINT N'VERIFY_REPORTS: усі перевірки пройдено (' + CAST(@total AS NVARCHAR(10)) + N').';
GO
