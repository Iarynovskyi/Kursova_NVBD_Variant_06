/* =====================================================================
   Файл: VERIFY_CUBE.sql
   Опис: Перевірка коректності та продуктивності OLAP-куба Polyclinic DW (Етап 4, п. 4.7)
     A. Структура куба (DMV): групи мір, типи агрегатних функцій, KPI, перспективи
     B. Звірка базових мір куба зі сховищем PolyclinicDW (кількості, суми, Distinct Count, Min/Max)
     C. Виміри: SCD2-версії, сніжинка МКХ-10, обчислювані члени вимірів
     D. MDX-обчислення: YTD, PY, YoY %, ковзне середнє, рейтинг і Top-N, бізнес-метрика, KPI
     E. Продуктивність: холодний і теплий кеш куба проти GROUP BY у реляційному сховищі
     F. Підсумок PASS / FAIL (RAISERROR при помилках)
   Механізм: linked server SSAS_POLYCLINIC (провайдер MSOLAP) — MDX і DMV виконуються
             через EXEC (...) AT, результат порівнюється з T-SQL по PolyclinicDW.
   Передумова: куб розгорнуто й оброблено (Process Full) на DESKTOP-I5COGTD.
   Запуск: SSMS, Database Engine, Windows-автентифікація (адміністратор SSAS).
   ===================================================================== */
USE master;
SET NOCOUNT ON;
GO
/* ---------- Linked server до Analysis Services (створюється один раз) ---------- */
EXEC master.dbo.sp_MSset_oledb_prop N'MSOLAP', N'AllowInProcess', 1;
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'SSAS_POLYCLINIC')
BEGIN
    EXEC master.dbo.sp_addlinkedserver @server = N'SSAS_POLYCLINIC', @srvproduct = N'', @provider = N'MSOLAP',
         @datasrc = N'DESKTOP-I5COGTD', @catalog = N'Polyclinic_OLAP';
    EXEC master.dbo.sp_addlinkedsrvlogin @rmtsrvname = N'SSAS_POLYCLINIC', @useself = N'True';
END;
EXEC master.dbo.sp_serveroption N'SSAS_POLYCLINIC', N'rpc out', N'true';
EXEC master.dbo.sp_serveroption N'SSAS_POLYCLINIC', N'remote proc transaction promotion', N'false';
GO
USE PolyclinicDW;
GO
DROP TABLE IF EXISTS #Checks, #V, #V3, #S, #M, #Perf;
CREATE TABLE #Checks (
    CheckID INT IDENTITY(1,1) PRIMARY KEY, CheckGroup NVARCHAR(40) NOT NULL, CheckName NVARCHAR(200) NOT NULL,
    Expected NVARCHAR(60) NOT NULL, Actual NVARCHAR(60) NULL, Passed BIT NOT NULL,
    Status AS (CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END));
CREATE TABLE #V  (v FLOAT NULL);                                   -- одна комірка MDX
CREATE TABLE #V3 (a FLOAT NULL, b FLOAT NULL, c FLOAT NULL);       -- три комірки (KPI)
CREATE TABLE #S  (s NVARCHAR(400) NULL);                           -- один рядковий стовпець (DMV)
CREATE TABLE #M  (caption NVARCHAR(400) NULL, v FLOAT NULL);       -- член + значення
CREATE TABLE #Perf (TestName NVARCHAR(200), DurationMs INT, RowsReturned INT);
GO

/* ---------------------------------------------------------------------
   A. СТРУКТУРА КУБА (DMV)
   --------------------------------------------------------------------- */
DECLARE @n INT, @types NVARCHAR(200);
INSERT INTO #S EXEC (N'SELECT [MEASUREGROUP_NAME] FROM $SYSTEM.MDSCHEMA_MEASUREGROUPS WHERE [CUBE_NAME] = ''Polyclinic DW''') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*) FROM #S;
INSERT INTO #Checks VALUES (N'A. Структура', N'Груп мір (Візити, Унікальні пацієнти, Рецепти, Завантаженість, Календар)', N'5', CAST(@n AS NVARCHAR(10)), IIF(@n = 5, 1, 0));

DELETE #S;
INSERT INTO #S EXEC (N'SELECT [MEASURE_AGGREGATOR] FROM $SYSTEM.MDSCHEMA_MEASURES WHERE [CUBE_NAME] = ''Polyclinic DW''') AT SSAS_POLYCLINIC;
SELECT @types = STRING_AGG(t, N', ') WITHIN GROUP (ORDER BY t) FROM (
    SELECT DISTINCT CASE s WHEN N'1' THEN N'Sum' WHEN N'2' THEN N'Count' WHEN N'3' THEN N'Min' WHEN N'4' THEN N'Max'
                           WHEN N'8' THEN N'DistinctCount' WHEN N'127' THEN N'Calculated' ELSE s END AS t FROM #S) x;
SELECT @n = COUNT(*) FROM #S WHERE s = N'127';
INSERT INTO #Checks VALUES (N'A. Структура', N'Типи мір: Sum, Count, Min, Max, DistinctCount, Calculated', N'6 типів', @types,
    IIF((SELECT COUNT(DISTINCT s) FROM #S WHERE s IN (N'1', N'2', N'3', N'4', N'8', N'127')) = 6, 1, 0));
INSERT INTO #Checks VALUES (N'A. Структура', N'Обчислюваних мір (мін. 3)', N'>= 3', CAST(@n AS NVARCHAR(10)), IIF(@n >= 3, 1, 0));

DELETE #S;
INSERT INTO #S EXEC (N'SELECT [KPI_NAME] FROM $SYSTEM.MDSCHEMA_KPIS WHERE [CUBE_NAME] = ''Polyclinic DW''') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*) FROM #S;
INSERT INTO #Checks VALUES (N'A. Структура', N'KPI (Ефективність лікування, Дохід від консультацій)', N'2', CAST(@n AS NVARCHAR(10)), IIF(@n = 2, 1, 0));

DELETE #S;
INSERT INTO #S EXEC (N'SELECT [CUBE_NAME] FROM $SYSTEM.MDSCHEMA_CUBES WHERE [BASE_CUBE_NAME] = ''Polyclinic DW''') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*) FROM #S;
INSERT INTO #Checks VALUES (N'A. Структура', N'Перспективи (Завантаженість лікарів, Клінічна аналітика, Фармація)', N'3', CAST(@n AS NVARCHAR(10)), IIF(@n = 3, 1, 0));

DELETE #S;
INSERT INTO #S EXEC (N'SELECT [DIMENSION_UNIQUE_NAME] FROM $SYSTEM.MDSCHEMA_DIMENSIONS WHERE [CUBE_NAME] = ''Polyclinic DW'' AND [DIMENSION_TYPE] <> 2') AT SSAS_POLYCLINIC;
SELECT @n = COUNT(*) FROM #S;
INSERT INTO #Checks VALUES (N'A. Структура', N'Вимірів куба (мін. 5; Дата — у двох ролях)', N'>= 5', CAST(@n AS NVARCHAR(10)), IIF(@n >= 5, 1, 0));
GO

/* ---------------------------------------------------------------------
   B. ЗВІРКА БАЗОВИХ МІР КУБА ЗІ СХОВИЩЕМ
   --------------------------------------------------------------------- */
DECLARE @cube FLOAT, @sql DECIMAL(18,2);

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість візитів]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(VisitCount) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Кількість візитів (Sum) = SUM(FactVisits.VisitCount)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість діагнозів]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = COUNT(*) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Кількість діагнозів (Count) = COUNT(FactVisits)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Вартість консультацій у грн]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(ConsultationCostUAH) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Вартість консультацій у грн = SUM(ConsultationCostUAH)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(ROUND(@cube, 2) AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Унікальних пацієнтів]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @sql = COUNT(DISTINCT p.PatientID_Source) FROM dbo.FactVisits f JOIN dbo.DimPatient p ON p.PatientKey = f.PatientKey;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Унікальних пацієнтів (DistinctCount) = COUNT(DISTINCT PatientID_Source)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Унікальних пацієнтів]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Рік].&[2024]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @sql = COUNT(DISTINCT p.PatientID_Source) FROM dbo.FactVisits f JOIN dbo.DimPatient p ON p.PatientKey = f.PatientKey WHERE f.DateKey BETWEEN 20240101 AND 20241231;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Унікальних пацієнтів за 2024 рік (неадитивна міра)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Вартість ліків у грн]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(TotalMedicationCostUAH) FROM dbo.FactPrescriptions;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Вартість ліків у грн = SUM(TotalMedicationCostUAH)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(ROUND(@cube, 2) AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість рецептів]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(PrescriptionCount) FROM dbo.FactPrescriptions;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Кількість рецептів = SUM(PrescriptionCount)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Максимальна ціна упаковки у грн]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = MAX(UnitPriceSnapshot) FROM dbo.FactPrescriptions;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Max ціни упаковки = MAX(UnitPriceSnapshot)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(ROUND(@cube, 2) AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Мінімальна тривалість прийому у хв]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = MIN(MinVisitDurationMinutes) FROM dbo.FactDoctorMonthlySummary;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Min тривалості прийому = MIN(MinVisitDurationMinutes)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Візитів за місяць]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(TotalVisitsCount) FROM dbo.FactDoctorMonthlySummary;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Завантаженість (ROLAP, гранулярність — місяць) = SUM(TotalVisitsCount)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість візитів]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Рік].&[2024]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(VisitCount) FROM dbo.FactVisits WHERE DateKey BETWEEN 20240101 AND 20241231;
INSERT INTO #Checks VALUES (N'B. Звірка', N'Візити за 2024 рік (зріз по ієрархії Календар)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість візитів]} ON 0 FROM [Polyclinic DW] WHERE [Джерело даних].[Джерело даних].&[BRANCH2]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(VisitCount) FROM dbo.FactVisits WHERE SourceSystem = N'BRANCH2';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Візити архіву Філії №2 (вимір Джерело даних)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Робочих днів]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Рік].&[2024]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = COUNT(*) FROM dbo.DimDate WHERE YearNumber = 2024 AND WorkingDayStatus = N'Робочий день';
INSERT INTO #Checks VALUES (N'B. Звірка', N'Робочих днів у 2024 році (Named Calculation IsWorkingDay)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));
GO

/* ---------------------------------------------------------------------
   C. ВИМІРИ: SCD2, СНІЖИНКА, ОБЧИСЛЮВАНІ ЧЛЕНИ
   --------------------------------------------------------------------- */
DECLARE @cube FLOAT, @sql DECIMAL(18,2);

DELETE #V; INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[n] AS [Лікар].[Версія лікаря].[Версія лікаря].MEMBERS.COUNT SELECT {[Measures].[n]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = COUNT(*) FROM dbo.DimDoctor;
INSERT INTO #Checks VALUES (N'C. Виміри', N'SCD2: членів «Версія лікаря» = рядків DimDoctor', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[n] AS [Пацієнт].[Пацієнт].[Пацієнт].MEMBERS.COUNT SELECT {[Measures].[n]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = COUNT(DISTINCT PatientID_Source) FROM dbo.DimPatient;
INSERT INTO #Checks VALUES (N'C. Виміри', N'SCD2: членів «Пацієнт» = унікальних пацієнтів (версії згруповано)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість діагнозів]} ON 0 FROM [Polyclinic DW] WHERE [Хвороба].[Розділ МКХ-10].&[J]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = COUNT(*) FROM dbo.FactVisits f JOIN dbo.DimDisease d ON d.DiseaseKey = f.DiseaseKey WHERE d.ICD10Chapter = 'J';
INSERT INTO #Checks VALUES (N'C. Виміри', N'Сніжинка: діагнози розділу J (Named Query розділів МКХ-10)', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість візитів]} ON 0 FROM [Polyclinic DW] WHERE [Вікова група].[Вікова група].[Усі].[Дорослі від 18 років]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(VisitCount) FROM dbo.FactVisits WHERE AgeGroupKey >= 2;
INSERT INTO #Checks VALUES (N'C. Виміри', N'Обчислюваний член «Дорослі від 18 років»', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Кількість візитів]} ON 0 FROM [Polyclinic DW] WHERE [Пацієнт].[Рік народження].[Усі].[Пенсійного віку (народжені до 1962 року)]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @sql = SUM(f.VisitCount) FROM dbo.FactVisits f JOIN dbo.DimPatient p ON p.PatientKey = f.PatientKey WHERE p.BirthYear <= 1961;
INSERT INTO #Checks VALUES (N'C. Виміри', N'Обчислюваний член «Пенсійного віку» виміру Пацієнт', CAST(@sql AS NVARCHAR(30)), CAST(CAST(@cube AS DECIMAL(18,2)) AS NVARCHAR(30)), IIF(ROUND(@cube, 2) = @sql, 1, 0));
GO

/* ---------------------------------------------------------------------
   D. MDX-ОБЧИСЛЕННЯ
   --------------------------------------------------------------------- */
DECLARE @cube FLOAT, @exp FLOAT, @v23 FLOAT, @v24 FLOAT, @mdx NVARCHAR(MAX);
SELECT @v23 = SUM(VisitCount) FROM dbo.FactVisits WHERE DateKey BETWEEN 20230101 AND 20231231;
SELECT @v24 = SUM(VisitCount) FROM dbo.FactVisits WHERE DateKey BETWEEN 20240101 AND 20241231;

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Візити з початку року (YTD)]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Місяць].&[202406]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @exp = SUM(VisitCount) FROM dbo.FactVisits WHERE DateKey BETWEEN 20240101 AND 20240630;
INSERT INTO #Checks VALUES (N'D. MDX', N'YTD: візити з 01.01 по 30.06.2024', CAST(@exp AS NVARCHAR(30)), CAST(@cube AS NVARCHAR(30)), IIF(@cube = @exp, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Візити попереднього року (PY)]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Рік].&[2024]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
INSERT INTO #Checks VALUES (N'D. MDX', N'PY: для 2024 року = візити 2023 року', CAST(@v23 AS NVARCHAR(30)), CAST(@cube AS NVARCHAR(30)), IIF(@cube = @v23, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Приріст візитів YoY]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Рік].&[2024]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SET @exp = (@v24 - @v23) / @v23;
INSERT INTO #Checks VALUES (N'D. MDX', N'YoY %: приріст візитів 2024 до 2023', FORMAT(@exp, 'P2'), FORMAT(@cube, 'P2'), IIF(ABS(@cube - @exp) < 0.000001, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Ковзне середнє візитів (3 періоди)]} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Місяць].&[202412]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V; SELECT @exp = SUM(VisitCount) / 3.0 FROM dbo.FactVisits WHERE DateKey BETWEEN 20241001 AND 20241231;
INSERT INTO #Checks VALUES (N'D. MDX', N'Ковзне середнє: жовтень–грудень 2024', FORMAT(@exp, 'N2'), FORMAT(@cube, 'N2'), IIF(ABS(@cube - @exp) < 0.001, 1, 0));

DELETE #V; INSERT INTO #V EXEC (N'SELECT {[Measures].[Частка одужань]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
SELECT @exp = 1.0 * SUM(IsRecoveredFlag) / SUM(CASE WHEN RecoveryDateKey <> 19000101 THEN 1 ELSE 0 END) FROM dbo.FactVisits;
INSERT INTO #Checks VALUES (N'D. MDX', N'Бізнес-метрика: частка одужань серед завершених випадків', FORMAT(@exp, 'P2'), FORMAT(@cube, 'P2'), IIF(ABS(@cube - @exp) < 0.000001, 1, 0));

-- Ranking / Top-N
DECLARE @topDoc INT, @topVisits FLOAT;
SELECT TOP (1) @topDoc = d.DoctorID_Source, @topVisits = SUM(f.VisitCount)
FROM dbo.FactVisits f JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey GROUP BY d.DoctorID_Source ORDER BY SUM(f.VisitCount) DESC;
DELETE #M; INSERT INTO #M EXEC (N'SELECT {[Measures].[Кількість візитів]} ON 0, HEAD([Топ-10 лікарів за візитами], 1) ON 1 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #M;
INSERT INTO #Checks VALUES (N'D. MDX', N'Top-N: лідер набору «Топ-10 лікарів за візитами»', CAST(@topVisits AS NVARCHAR(30)), CAST(@cube AS NVARCHAR(30)), IIF(@cube = @topVisits, 1, 0));
DELETE #V; INSERT INTO #V EXEC (N'WITH MEMBER [Measures].[n] AS [Топ-10 лікарів за візитами].COUNT SELECT {[Measures].[n]} ON 0 FROM [Polyclinic DW]') AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
INSERT INTO #Checks VALUES (N'D. MDX', N'Top-N: у наборі рівно 10 лікарів', N'10', CAST(@cube AS NVARCHAR(30)), IIF(@cube = 10, 1, 0));
SET @mdx = N'SELECT {[Measures].[Рейтинг лікаря за візитами]} ON 0 FROM [Polyclinic DW] WHERE [Лікар].[Лікар].&[' + CAST(@topDoc AS NVARCHAR(10)) + N']';
DELETE #V; INSERT INTO #V EXEC (@mdx) AT SSAS_POLYCLINIC;
SELECT @cube = v FROM #V;
INSERT INTO #Checks VALUES (N'D. MDX', N'Ranking: позиція лідера в рейтингу лікарів', N'1', CAST(@cube AS NVARCHAR(30)), IIF(@cube = 1, 1, 0));

-- KPI «Ефективність лікування» за 2024 рік
DECLARE @rate24 FLOAT, @status FLOAT;
SELECT @rate24 = 1.0 * SUM(IsRecoveredFlag) / SUM(CASE WHEN RecoveryDateKey <> 19000101 THEN 1 ELSE 0 END)
FROM dbo.FactVisits WHERE DateKey BETWEEN 20240101 AND 20241231;
SET @status = CASE WHEN @rate24 >= 0.70 THEN 1 WHEN @rate24 >= 0.63 THEN 0 ELSE -1 END;
DELETE #V3; INSERT INTO #V3 EXEC (N'SELECT {KPIValue("Ефективність лікування"), KPIGoal("Ефективність лікування"), KPIStatus("Ефективність лікування")} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Рік].&[2024]') AT SSAS_POLYCLINIC;
INSERT INTO #Checks SELECT N'D. MDX', N'KPI «Ефективність лікування» 2024: значення / ціль / статус',
    CONCAT(FORMAT(@rate24, 'P1'), N' / 70% / ', @status), CONCAT(FORMAT(a, 'P1'), N' / ', FORMAT(b, 'P0'), N' / ', c),
    IIF(ABS(a - @rate24) < 0.000001 AND b = 0.70 AND c = @status, 1, 0) FROM #V3;

-- KPI «Дохід від консультацій» за 2024 рік: ціль = PY × 1.05
DECLARE @c23 FLOAT, @c24 FLOAT;
SELECT @c23 = SUM(ConsultationCostUAH) FROM dbo.FactVisits WHERE DateKey BETWEEN 20230101 AND 20231231;
SELECT @c24 = SUM(ConsultationCostUAH) FROM dbo.FactVisits WHERE DateKey BETWEEN 20240101 AND 20241231;
SET @status = CASE WHEN @c24 >= @c23 * 1.05 THEN 1 WHEN @c24 >= @c23 * 1.05 * 0.95 THEN 0 ELSE -1 END;
DELETE #V3; INSERT INTO #V3 EXEC (N'SELECT {KPIValue("Дохід від консультацій"), KPIGoal("Дохід від консультацій"), KPIStatus("Дохід від консультацій")} ON 0 FROM [Polyclinic DW] WHERE [Дата].[Календар].[Рік].&[2024]') AT SSAS_POLYCLINIC;
INSERT INTO #Checks SELECT N'D. MDX', N'KPI «Дохід від консультацій» 2024: ціль = PY × 1,05; статус',
    CONCAT(FORMAT(@c23 * 1.05, 'N0'), N' / ', @status), CONCAT(FORMAT(b, 'N0'), N' / ', c),
    IIF(ABS(b - @c23 * 1.05) < 0.01 AND ABS(a - @c24) < 0.01 AND c = @status, 1, 0) FROM #V3;
GO

/* ---------------------------------------------------------------------
   E. ПРОДУКТИВНІСТЬ: КУБ (ХОЛОДНИЙ / ТЕПЛИЙ КЕШ) ПРОТИ РЕЛЯЦІЙНОГО СХОВИЩА
   Запит: візити, вартість і середня тривалість по відділеннях × роках (2016–2025)
   --------------------------------------------------------------------- */
DECLARE @t0 DATETIME2(3), @rows INT, @cold INT, @warm INT, @rel INT;
DROP TABLE IF EXISTS #Big;
CREATE TABLE #Big (c1 NVARCHAR(400), c2 NVARCHAR(100), m1 FLOAT, m2 FLOAT, m3 FLOAT);
DECLARE @q NVARCHAR(MAX) = N'SELECT {[Measures].[Кількість візитів], [Measures].[Вартість консультацій у грн], [Measures].[Середня тривалість прийому у хв]} ON 0,
NON EMPTY [Лікар].[Відділення].[Відділення].MEMBERS * [Дата].[Рік].[Рік].MEMBERS ON 1 FROM [Polyclinic DW]';

EXEC (N'<ClearCache xmlns="http://schemas.microsoft.com/analysisservices/2003/engine"><Object><DatabaseID>Polyclinic_OLAP</DatabaseID></Object></ClearCache>') AT SSAS_POLYCLINIC;
SET @t0 = SYSDATETIME();
INSERT INTO #Big EXEC (@q) AT SSAS_POLYCLINIC;
SET @rows = @@ROWCOUNT; SET @cold = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
INSERT INTO #Perf VALUES (N'OLAP: відділення × рік, холодний кеш', @cold, @rows);

DELETE #Big; SET @t0 = SYSDATETIME();
INSERT INTO #Big EXEC (@q) AT SSAS_POLYCLINIC;
SET @rows = @@ROWCOUNT; SET @warm = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
INSERT INTO #Perf VALUES (N'OLAP: відділення × рік, теплий кеш', @warm, @rows);

DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t0 = SYSDATETIME();
SELECT @rows = COUNT(*) FROM (
    SELECT d.DepartmentName, dt.YearNumber, SUM(f.VisitCount) AS V, SUM(f.ConsultationCostUAH) AS C,
           1.0 * SUM(f.DurationMinutes) / NULLIF(SUM(f.VisitCount), 0) AS A
    FROM dbo.FactVisits f JOIN dbo.DimDoctor d ON d.DoctorKey = f.DoctorKey JOIN dbo.DimDate dt ON dt.DateKey = f.DateKey
    GROUP BY d.DepartmentName, dt.YearNumber) x;
SET @rel = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
INSERT INTO #Perf VALUES (N'ROLAP-еквівалент: GROUP BY у PolyclinicDW (холодний буфер)', @rel, @rows);

INSERT INTO #Checks VALUES (N'E. Продуктивність', N'Теплий кеш куба не повільніший за холодний', CONCAT(N'<= ', @cold, N' мс'), CONCAT(@warm, N' мс'), IIF(@warm <= @cold, 1, 0));
SELECT TestName, DurationMs, RowsReturned FROM #Perf;
GO

/* ---------------------------------------------------------------------
   F. ПІДСУМОК
   --------------------------------------------------------------------- */
SELECT CheckID, CheckGroup, CheckName, Expected, Actual, Status FROM #Checks ORDER BY CheckID;
DECLARE @Failed INT = (SELECT COUNT(*) FROM #Checks WHERE Passed = 0), @Total INT = (SELECT COUNT(*) FROM #Checks);
DECLARE @Summary NVARCHAR(200) = N'VERIFY_CUBE: ' + CAST(@Total - @Failed AS NVARCHAR(10)) + N' / ' + CAST(@Total AS NVARCHAR(10)) + N' перевірок пройдено';
IF @Failed > 0 RAISERROR(@Summary, 16, 1); ELSE PRINT @Summary;
GO
