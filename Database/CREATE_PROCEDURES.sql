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
   ФУНКЦІЯ 2 (Таблична): Отримання повного списку протипоказаних ліків для пацієнта
   Об'єднує особисті алергії та протипоказання через хвороби пацієнта
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.ufn_GetPatientContraindicatedMedications (
    @PatientID INT
)
RETURNS TABLE
AS
RETURN
(
    -- 1. Особисті алергії пацієнта
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

    -- 2. Протипоказання через наявні або хронічні хвороби пацієнта
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
    @ConsultationCost DECIMAL(10,2),
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
            DurationMinutes, ConsultationCost, Complaints
        )
        VALUES (
            @PatientID, @DoctorID, @VisitDateTime, @VisitType, 
            @DurationMinutes, @ConsultationCost, @Complaints
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

    UPDATE dbo.Diagnoses
    SET 
        TreatmentOutcome = @TreatmentOutcome,
        RecoveryDate = @RecoveryDate,
        SickLeaveDays = ISNULL(@TotalSickLeaveDays, SickLeaveDays),
        UpdatedAt = SYSDATETIME()
    WHERE DiagnosisID = @DiagnosisID;
END;
GO

/* ---------------------------------------------------------------------
   ПРОЦЕДУРА 4: Аналіз завантаженості лікарів по місяцях (на базі OLTP)
   Використовується для:
   1) Звіту №3 "Завантаженість лікарів по місяцях"
   2) Порівняння часу виконання запитів OLTP vs OLAP (Додаткові вимоги, п. 2)
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
        doc.DoctorID,
        doc.LastName + N' ' + doc.FirstName + ISNULL(N' ' + doc.MiddleName, N'') AS DoctorFullName,
        doc.QualificationCategory,
        COUNT(v.VisitID) AS TotalVisits,
        COUNT(DISTINCT v.PatientID) AS UniquePatients,
        SUM(v.DurationMinutes) AS TotalMinutesSpent,
        CAST(SUM(v.DurationMinutes) / 60.0 AS DECIMAL(10,2)) AS TotalHoursSpent,
        SUM(v.ConsultationCost) AS TotalConsultationRevenue
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

PRINT N'Усі функції та збережені процедури успішно створено.';
GO