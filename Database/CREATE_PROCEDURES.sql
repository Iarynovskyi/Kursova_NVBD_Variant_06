/* =====================================================================
   Файл: CREATE_PROCEDURES.sql
   Опис: Створення користувацьких функцій (UDF) та збережених процедур
   ===================================================================== */

USE PolyclinicOLTP;
GO

/* ---------------------------------------------------------------------
   ФУНКЦІЯ 1 (Скалярна): Обчислення повного віку пацієнта на вказану дату
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.ufn_GetPatientAge (
    @BirthDate DATE,
    @TargetDate DATE
)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    RETURN (
        DATEDIFF(YEAR, @BirthDate, @TargetDate) - 
        CASE 
            WHEN (MONTH(@BirthDate) > MONTH(@TargetDate)) OR 
                 (MONTH(@BirthDate) = MONTH(@TargetDate) AND DAY(@BirthDate) > DAY(@TargetDate))
            THEN 1 
            ELSE 0 
        END
    );
END;
GO

/* ---------------------------------------------------------------------
   ФУНКЦІЯ 2 (Скалярна): Динамічний розрахунок вартості прийому
   На основі витраченого часу (DurationMinutes) та погодинної ставки (HourlyRate)
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.ufn_CalculateVisitCost (
    @DurationMinutes SMALLINT,
    @HourlyRate DECIMAL(10,2),
    @IsFreeNSZU BIT
)
RETURNS DECIMAL(10,2)
WITH SCHEMABINDING
AS
BEGIN
    IF @IsFreeNSZU = 1
        RETURN 0.00;

    RETURN CAST((@DurationMinutes / 60.0) * @HourlyRate AS DECIMAL(10,2));
END;
GO

/* ---------------------------------------------------------------------
   ФУНКЦІЯ 3 (Таблична): Отримання повного списку протипоказаних ліків для пацієнта
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.ufn_GetPatientContraindicatedMedications (
    @PatientID INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT 
        m.MedicationID,
        m.TradeName,
        m.ActiveSubstance,
        N'Індивідуальна непереносимість: ' + pc.ReactionType AS Reason,
        pc.SeverityLevel
    FROM dbo.PatientContraindications pc
    INNER JOIN dbo.Medications m ON pc.MedicationID = m.MedicationID
    WHERE pc.PatientID = @PatientID

    UNION

    SELECT DISTINCT
        m.MedicationID,
        m.TradeName,
        m.ActiveSubstance,
        N'Протипоказано при діагнозі: ' + dis.DiseaseName + N' (' + dis.ICD10Code + N')' AS Reason,
        mdc.SeverityLevel
    FROM dbo.Visits v
    INNER JOIN dbo.Diagnoses diag ON v.VisitID = diag.VisitID
    INNER JOIN dbo.Diseases dis ON diag.DiseaseID = dis.DiseaseID
    INNER JOIN dbo.MedicationDiseaseContraindications mdc ON dis.DiseaseID = mdc.DiseaseID
    INNER JOIN dbo.Medications m ON mdc.MedicationID = m.MedicationID
    WHERE v.PatientID = @PatientID
      AND (dis.IsChronic = 1 OR diag.TreatmentOutcome = N'В процесі')
);
GO

/* ---------------------------------------------------------------------
   ПРОЦЕДУРА 1: Реєстрація амбулаторного прийому та первинного діагнозу
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RegisterVisitAndDiagnosis
    @PatientID INT,
    @DoctorID INT,
    @VisitDateTime DATETIME2(0),
    @VisitType NVARCHAR(30),
    @DurationMinutes SMALLINT,
    @IsFreeNSZU BIT = 0,
    @Complaints NVARCHAR(500),
    @DiseaseID INT,
    @Severity NVARCHAR(20),
    @SickLeaveDays SMALLINT = 0,
    @NewVisitID BIGINT OUTPUT,
    @NewDiagnosisID BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.Visits (
            PatientID, DoctorID, VisitDateTime, VisitType, 
            DurationMinutes, IsFreeNSZU, Complaints
        )
        VALUES (
            @PatientID, @DoctorID, @VisitDateTime, @VisitType, 
            @DurationMinutes, @IsFreeNSZU, @Complaints
        );

        SET @NewVisitID = SCOPE_IDENTITY();

        INSERT INTO dbo.Diagnoses (
            VisitID, DiseaseID, DiagnosisDate, IsPrimary, 
            Severity, TreatmentOutcome, SickLeaveDays
        )
        VALUES (
            @NewVisitID, @DiseaseID, CAST(@VisitDateTime AS DATE), 1, 
            @Severity, N'В процесі', @SickLeaveDays
        );

        SET @NewDiagnosisID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   ПРОЦЕДУРА 2: Безпечне призначення медикаментів (виписка рецепта)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_PrescribeMedication
    @DiagnosisID BIGINT,
    @MedicationID INT,
    @DailyDosage NVARCHAR(50),
    @DurationDays SMALLINT,
    @QuantityPackages TINYINT,
    @IsSubsidized BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.Prescriptions (
            DiagnosisID, MedicationID, DailyDosage, 
            DurationDays, QuantityPackages, IsSubsidized
        )
        VALUES (
            @DiagnosisID, @MedicationID, @DailyDosage, 
            @DurationDays, @QuantityPackages, @IsSubsidized
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   ПРОЦЕДУРА 3: Закриття історії хвороби та фіксація результату лікування
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_CloseDiagnosisCase
    @DiagnosisID BIGINT,
    @TreatmentOutcome NVARCHAR(30),
    @RecoveryDate DATE,
    @TotalSickLeaveDays SMALLINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Валідація вхідних параметрів (бізнес-правила закриття випадку)
    IF @TreatmentOutcome = N'В процесі'
        THROW 50010, N'Закриття випадку: результат лікування не може бути "В процесі".', 1;
    IF @RecoveryDate IS NULL
        THROW 50011, N'Закриття випадку: потрібно вказати дату завершення лікування.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Diagnoses WHERE DiagnosisID = @DiagnosisID)
        THROW 50012, N'Закриття випадку: діагноз з таким ідентифікатором не знайдено.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Diagnoses WHERE DiagnosisID = @DiagnosisID AND TreatmentOutcome <> N'В процесі')
        THROW 50013, N'Закриття випадку: випадок уже закрито раніше.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.Diagnoses
        SET 
            TreatmentOutcome = @TreatmentOutcome,
            RecoveryDate = @RecoveryDate,
            SickLeaveDays = ISNULL(@TotalSickLeaveDays, SickLeaveDays),
            UpdatedAt = SYSDATETIME()
        WHERE DiagnosisID = @DiagnosisID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   ПРОЦЕДУРА 4: Аналіз завантаженості лікарів по місяцях (на базі OLTP)
   Динамічно обчислює вартість візитів через DurationMinutes та HourlyRate
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetDoctorMonthlyWorkload
    @StartDate DATE,
    @EndDate DATE,
    @DepartmentID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        YEAR(v.VisitDateTime) AS VisitYear,
        MONTH(v.VisitDateTime) AS VisitMonth,
        dep.DepartmentName,
        spec.SpecialtyName,
        spec.HourlyRate,
        doc.DoctorID,
        doc.LastName + N' ' + doc.FirstName + ISNULL(N' ' + doc.MiddleName, N'') AS DoctorFullName,
        doc.QualificationCategory,
        COUNT(v.VisitID) AS TotalVisits,
        COUNT(DISTINCT v.PatientID) AS UniquePatients,
        SUM(v.DurationMinutes) AS TotalMinutesSpent,
        CAST(SUM(v.DurationMinutes) / 60.0 AS DECIMAL(10,2)) AS TotalHoursSpent,
        SUM(dbo.ufn_CalculateVisitCost(v.DurationMinutes, spec.HourlyRate, v.IsFreeNSZU)) AS CalculatedRevenue
    FROM dbo.Visits v
    INNER JOIN dbo.Doctors doc ON v.DoctorID = doc.DoctorID
    INNER JOIN dbo.Departments dep ON doc.DepartmentID = dep.DepartmentID
    INNER JOIN dbo.Specialties spec ON doc.SpecialtyID = spec.SpecialtyID
    WHERE v.VisitDateTime >= @StartDate 
      AND v.VisitDateTime < DATEADD(DAY, 1, @EndDate)
      AND (@DepartmentID IS NULL OR dep.DepartmentID = @DepartmentID)
    GROUP BY 
        YEAR(v.VisitDateTime),
        MONTH(v.VisitDateTime),
        dep.DepartmentName,
        spec.SpecialtyName,
        spec.HourlyRate,
        doc.DoctorID,
        doc.LastName,
        doc.FirstName,
        doc.MiddleName,
        doc.QualificationCategory
    ORDER BY 
        VisitYear DESC, 
        VisitMonth DESC, 
        TotalVisits DESC;
END;
GO

/* ---------------------------------------------------------------------
   ПРОЦЕДУРА 5: Історія хвороби пацієнта (основа для звіту "Історія хвороби пацієнта")
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetPatientMedicalHistory
    @PatientID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        v.VisitID,
        v.VisitDateTime,
        v.VisitType,
        doc.LastName + N' ' + doc.FirstName + ISNULL(N' ' + doc.MiddleName, N'') AS DoctorFullName,
        spec.SpecialtyName,
        dis.ICD10Code,
        dis.DiseaseName,
        diag.IsPrimary,
        diag.Severity,
        diag.TreatmentOutcome,
        diag.RecoveryDate,
        diag.SickLeaveDays,
        (SELECT COUNT(*) FROM dbo.Prescriptions pr WHERE pr.DiagnosisID = diag.DiagnosisID) AS PrescriptionsCount,
        v.Complaints
    FROM dbo.Visits v
    INNER JOIN dbo.Diagnoses diag ON diag.VisitID = v.VisitID
    INNER JOIN dbo.Diseases dis ON dis.DiseaseID = diag.DiseaseID
    INNER JOIN dbo.Doctors doc ON doc.DoctorID = v.DoctorID
    INNER JOIN dbo.Specialties spec ON spec.SpecialtyID = doc.SpecialtyID
    WHERE v.PatientID = @PatientID
    ORDER BY v.VisitDateTime DESC, diag.IsPrimary DESC;
END;
GO

PRINT N'Усі функції та збережені процедури успішно оновлено.';
GO