/* =====================================================================
   Файл: RUN_ETL_PIPELINE.sql
   Опис: Процедури завантаження сховища PolyclinicDW (Етап 3) та еталонний T-SQL ETL

   1. etl.usp_StartExecution / usp_FinishExecution / usp_FailExecution / usp_LogTask
      — аудит запусків (викликаються з Execute SQL Task та Event Handler OnError у SSIS)
   2. etl.usp_GetWatermark / usp_SetWatermark — інкрементальне завантаження
   3. etl.usp_Load_DimDisease, usp_Load_DimMedication      — SCD Type 1 (MERGE)
      etl.usp_Load_DimPatient_SCD2, usp_Load_DimDoctor_SCD2 — SCD Type 2 + Type 1
   4. etl.usp_Load_FactVisits, usp_Load_FactPrescriptions  — інкрементальний UPSERT (MERGE) зі staging
      etl.usp_Rebuild_FactDoctorMonthlySummary             — агрегація (лише змінені місяці)
   5. etl.usp_ResetForFullLoad                              — підготовка до повного перезавантаження
   6. etl.usp_RunReferenceETL (@LoadType = Full | Incremental)
      — еталонний ETL на чистому T-SQL (OLTP -> stg -> DW) для звірки та порівняння
        продуктивності з пакетами SSIS. SSIS-пакети використовують ті самі stg-таблиці та
        процедури завантаження, але трансформації (очищення, конвертація, Lookup тощо)
        виконують у Data Flow.
   ===================================================================== */

USE PolyclinicDW;
GO

/* =====================================================================
   1. АУДИТ ЗАПУСКІВ
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_StartExecution
    @PackageName       NVARCHAR(100),
    @LoadType          NVARCHAR(20) = N'Incremental',
    @ParentExecutionID INT = NULL,
    @ExecutionID       INT = NULL OUTPUT,
    @ReturnResultSet   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @ParentExecutionID = 0 SET @ParentExecutionID = NULL;   -- SSIS передає 0, якщо батьківського пакета немає
    INSERT INTO etl.PackageExecutionLog (PackageName, LoadType, ParentExecutionID, StartTime, ExecutionStatus)
    VALUES (@PackageName, @LoadType, @ParentExecutionID, SYSDATETIME(), N'Running');
    SET @ExecutionID = SCOPE_IDENTITY();
    IF @ReturnResultSet = 1 SELECT @ExecutionID AS ExecutionID;   -- для Execute SQL Task (Single row)
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_LogTask
    @ExecutionID  INT,
    @TaskName     NVARCHAR(150),
    @RowsRead     INT = 0,
    @RowsInserted INT = 0,
    @RowsUpdated  INT = 0,
    @RowsRejected INT = 0,
    @StartTime    DATETIME2(0) = NULL,
    @Notes        NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.TaskLog (ExecutionID, TaskName, StartTime, EndTime, RowsRead, RowsInserted, RowsUpdated, RowsRejected, Notes)
    VALUES (@ExecutionID, @TaskName, ISNULL(@StartTime, SYSDATETIME()), SYSDATETIME(),
            ISNULL(@RowsRead, 0), ISNULL(@RowsInserted, 0), ISNULL(@RowsUpdated, 0), ISNULL(@RowsRejected, 0), @Notes);
END;
GO

-- Підсумки запуску: якщо лічильники не передано — сумуються з журналу задач (у т.ч. дочірніх пакетів)
CREATE OR ALTER PROCEDURE etl.usp_FinishExecution
    @ExecutionID   INT,
    @RowsExtracted INT = NULL,
    @RowsInserted  INT = NULL,
    @RowsUpdated   INT = NULL,
    @RowsRejected  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH tasks AS (
        SELECT SUM(t.RowsRead) AS R, SUM(t.RowsInserted) AS I, SUM(t.RowsUpdated) AS U, SUM(t.RowsRejected) AS J
        FROM etl.TaskLog t
        WHERE t.ExecutionID = @ExecutionID
           OR t.ExecutionID IN (SELECT c.ExecutionID FROM etl.PackageExecutionLog c WHERE c.ParentExecutionID = @ExecutionID)
    )
    UPDATE l SET
        EndTime         = SYSDATETIME(),
        ExecutionStatus = N'Success',
        RowsExtracted   = ISNULL(@RowsExtracted, ISNULL(tasks.R, 0)),
        RowsInserted    = ISNULL(@RowsInserted,  ISNULL(tasks.I, 0)),
        RowsUpdated     = ISNULL(@RowsUpdated,   ISNULL(tasks.U, 0)),
        RowsRejected    = ISNULL(@RowsRejected,  ISNULL(tasks.J, 0))
    FROM etl.PackageExecutionLog l CROSS JOIN tasks
    WHERE l.ExecutionID = @ExecutionID;
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_FailExecution
    @ExecutionID  INT,
    @ErrorMessage NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.PackageExecutionLog
    SET EndTime = SYSDATETIME(), ExecutionStatus = N'Failed',
        ErrorMessage = LEFT(ISNULL(ErrorMessage + N' | ', N'') + @ErrorMessage, 4000)
    WHERE ExecutionID = @ExecutionID;
END;
GO

/* =====================================================================
   2. WATERMARKS (інкрементальне завантаження)
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_GetWatermark
    @TableName VARCHAR(50),
    @LastLoadedValue DATETIME2(0) = NULL OUTPUT,
    @ReturnResultSet BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @LastLoadedValue = LastLoadedValue FROM etl.Watermarks WHERE TableName = @TableName;
    IF @LastLoadedValue IS NULL
        THROW 50201, N'Watermark для вказаної таблиці не знайдено.', 1;
    IF @ReturnResultSet = 1 SELECT @LastLoadedValue AS LastLoadedValue;
END;
GO

-- Watermark лише зростає: значення = максимальна мітка часу фактично завантажених рядків
CREATE OR ALTER PROCEDURE etl.usp_SetWatermark
    @TableName   VARCHAR(50),
    @NewValue    DATETIME2(0),
    @ExecutionID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.Watermarks
    SET LastLoadedValue = @NewValue, LastExecutionID = @ExecutionID, LastUpdated = SYSDATETIME()
    WHERE TableName = @TableName AND @NewValue IS NOT NULL AND @NewValue > LastLoadedValue;
END;
GO

/* =====================================================================
   3. ВИМІРИ
   ===================================================================== */

-- 3.1 DimDisease — SCD Type 1
CREATE OR ALTER PROCEDURE etl.usp_Load_DimDisease
    @ExecutionID INT = NULL,
    @Inserted INT = 0 OUTPUT,
    @Updated  INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @act TABLE (A NVARCHAR(10));
    MERGE dbo.DimDisease AS t
    USING stg.Disease AS s ON t.DiseaseID_Source = s.DiseaseID
    WHEN MATCHED AND EXISTS (SELECT t.ICD10Code, t.ICD10Chapter, t.DiseaseName, t.DiseaseCategory, t.IsChronic, t.ChronicStatusName, t.ProfileSpecialtyName
                             EXCEPT
                             SELECT s.ICD10Code, s.ICD10Chapter, s.DiseaseName, s.DiseaseCategory, s.IsChronic, s.ChronicStatusName, s.ProfileSpecialtyName)
        THEN UPDATE SET t.ICD10Code = s.ICD10Code, t.ICD10Chapter = s.ICD10Chapter, t.DiseaseName = s.DiseaseName,
                        t.DiseaseCategory = s.DiseaseCategory, t.IsChronic = s.IsChronic,
                        t.ChronicStatusName = s.ChronicStatusName, t.ProfileSpecialtyName = s.ProfileSpecialtyName
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (DiseaseID_Source, ICD10Code, ICD10Chapter, DiseaseName, DiseaseCategory, IsChronic, ChronicStatusName, ProfileSpecialtyName)
             VALUES (s.DiseaseID, s.ICD10Code, s.ICD10Chapter, s.DiseaseName, s.DiseaseCategory, s.IsChronic, s.ChronicStatusName, s.ProfileSpecialtyName)
    OUTPUT $action INTO @act;
    SELECT @Inserted = SUM(CASE WHEN A = 'INSERT' THEN 1 ELSE 0 END), @Updated = SUM(CASE WHEN A = 'UPDATE' THEN 1 ELSE 0 END) FROM @act;
    SELECT @Inserted = ISNULL(@Inserted, 0), @Updated = ISNULL(@Updated, 0);
END;
GO

-- 3.2 DimMedication — SCD Type 1
CREATE OR ALTER PROCEDURE etl.usp_Load_DimMedication
    @ExecutionID INT = NULL,
    @Inserted INT = 0 OUTPUT,
    @Updated  INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @act TABLE (A NVARCHAR(10));
    MERGE dbo.DimMedication AS t
    USING stg.Medication AS s ON t.MedicationID_Source = s.MedicationID
    WHEN MATCHED AND EXISTS (SELECT t.RegistrationCode, t.TradeName, t.ActiveSubstance, t.PharmacologicalGroup, t.ReleaseForm,
                                    t.Manufacturer, t.ManufacturerCountry, t.IsDomestic, t.UnitPrice, t.PriceCategory
                             EXCEPT
                             SELECT s.RegistrationCode, s.TradeName, s.ActiveSubstance, s.PharmacologicalGroup, s.ReleaseForm,
                                    s.Manufacturer, s.ManufacturerCountry, s.IsDomestic, s.UnitPrice, s.PriceCategory)
        THEN UPDATE SET t.RegistrationCode = s.RegistrationCode, t.TradeName = s.TradeName, t.ActiveSubstance = s.ActiveSubstance,
                        t.PharmacologicalGroup = s.PharmacologicalGroup, t.ReleaseForm = s.ReleaseForm, t.Manufacturer = s.Manufacturer,
                        t.ManufacturerCountry = s.ManufacturerCountry, t.IsDomestic = s.IsDomestic,
                        t.UnitPrice = s.UnitPrice, t.PriceCategory = s.PriceCategory
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (MedicationID_Source, RegistrationCode, TradeName, ActiveSubstance, PharmacologicalGroup, ReleaseForm,
                     Manufacturer, ManufacturerCountry, IsDomestic, UnitPrice, PriceCategory)
             VALUES (s.MedicationID, s.RegistrationCode, s.TradeName, s.ActiveSubstance, s.PharmacologicalGroup, s.ReleaseForm,
                     s.Manufacturer, s.ManufacturerCountry, s.IsDomestic, s.UnitPrice, s.PriceCategory)
    OUTPUT $action INTO @act;
    SELECT @Inserted = SUM(CASE WHEN A = 'INSERT' THEN 1 ELSE 0 END), @Updated = SUM(CASE WHEN A = 'UPDATE' THEN 1 ELSE 0 END) FROM @act;
    SELECT @Inserted = ISNULL(@Inserted, 0), @Updated = ISNULL(@Updated, 0);
END;
GO

/* 3.3 DimPatient — SCD Type 2 (DistrictName, AddressLine) + SCD Type 1 (решта)
   • Type 1: зміни ПІБ, РНОКПП, групи крові, телефону перезаписуються в усіх версіях.
   • Type 2: при зміні району/адреси поточна версія закривається (ValidTo = @EffectiveDate,
     IsCurrent = 0) і створюється нова версія з ValidFrom = @EffectiveDate.
   • Перша версія нового пацієнта: ValidFrom = 1900-01-01 (покриває всю історію фактів). */
CREATE OR ALTER PROCEDURE etl.usp_Load_DimPatient_SCD2
    @ExecutionID   INT = NULL,
    @EffectiveDate DATETIME2(0) = NULL,
    @Inserted      INT = 0 OUTPUT,     -- нові пацієнти
    @NewVersions   INT = 0 OUTPUT,     -- нові версії (SCD2)
    @Type1Updated  INT = 0 OUTPUT      -- перезаписані рядки (SCD1)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Eff DATETIME2(0) = ISNULL(@EffectiveDate, SYSDATETIME());

    -- Type 1
    UPDATE d SET d.MedicalCardNumber = s.MedicalCardNumber, d.TaxCode = s.TaxCode, d.FullName = s.FullName,
                 d.BirthDate = s.BirthDate, d.BirthYear = YEAR(s.BirthDate), d.Gender = s.Gender, d.GenderName = s.GenderName,
                 d.BloodType = s.BloodType, d.Phone = s.Phone, d.RegistrationDate = s.RegistrationDate
    FROM dbo.DimPatient d JOIN stg.Patient s ON s.PatientID = d.PatientID_Source
    WHERE EXISTS (SELECT d.MedicalCardNumber, d.TaxCode, d.FullName, d.BirthDate, d.Gender, d.BloodType, d.Phone, d.RegistrationDate
                  EXCEPT
                  SELECT s.MedicalCardNumber, s.TaxCode, s.FullName, s.BirthDate, s.Gender, s.BloodType, s.Phone, s.RegistrationDate);
    SET @Type1Updated = @@ROWCOUNT;

    -- Type 2: пацієнти, у яких змінилися атрибути історії
    DECLARE @chg TABLE (PatientID INT PRIMARY KEY);
    INSERT INTO @chg (PatientID)
    SELECT s.PatientID
    FROM stg.Patient s JOIN dbo.DimPatient d ON d.PatientID_Source = s.PatientID AND d.IsCurrent = 1
    WHERE EXISTS (SELECT d.DistrictName, d.AddressLine EXCEPT SELECT s.DistrictName, s.AddressLine);

    UPDATE d SET d.ValidTo = @Eff, d.IsCurrent = 0
    FROM dbo.DimPatient d JOIN @chg c ON c.PatientID = d.PatientID_Source
    WHERE d.IsCurrent = 1;

    INSERT INTO dbo.DimPatient (PatientID_Source, MedicalCardNumber, TaxCode, FullName, BirthDate, BirthYear, Gender, GenderName,
                                BloodType, DistrictName, AddressLine, Phone, RegistrationDate, ValidFrom, ValidTo, IsCurrent)
    SELECT s.PatientID, s.MedicalCardNumber, s.TaxCode, s.FullName, s.BirthDate, YEAR(s.BirthDate), s.Gender, s.GenderName,
           s.BloodType, s.DistrictName, s.AddressLine, s.Phone, s.RegistrationDate, @Eff, '9999-12-31', 1
    FROM stg.Patient s JOIN @chg c ON c.PatientID = s.PatientID;
    SET @NewVersions = @@ROWCOUNT;

    -- Нові пацієнти
    INSERT INTO dbo.DimPatient (PatientID_Source, MedicalCardNumber, TaxCode, FullName, BirthDate, BirthYear, Gender, GenderName,
                                BloodType, DistrictName, AddressLine, Phone, RegistrationDate, ValidFrom, ValidTo, IsCurrent)
    SELECT s.PatientID, s.MedicalCardNumber, s.TaxCode, s.FullName, s.BirthDate, YEAR(s.BirthDate), s.Gender, s.GenderName,
           s.BloodType, s.DistrictName, s.AddressLine, s.Phone, s.RegistrationDate, '1900-01-01', '9999-12-31', 1
    FROM stg.Patient s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.DimPatient d WHERE d.PatientID_Source = s.PatientID);
    SET @Inserted = @@ROWCOUNT;
END;
GO

/* 3.4 DimDoctor — SCD Type 2 (відділення, спеціальність, категорія, погодинна ставка) + SCD Type 1 */
CREATE OR ALTER PROCEDURE etl.usp_Load_DimDoctor_SCD2
    @ExecutionID   INT = NULL,
    @EffectiveDate DATETIME2(0) = NULL,
    @Inserted      INT = 0 OUTPUT,
    @NewVersions   INT = 0 OUTPUT,
    @Type1Updated  INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Eff DATETIME2(0) = ISNULL(@EffectiveDate, SYSDATETIME());

    UPDATE d SET d.LicenseNumber = s.LicenseNumber, d.FullName = s.FullName, d.FloorNumber = s.FloorNumber,
                 d.StandardConsultMinutes = s.StandardConsultMinutes, d.HireDate = s.HireDate,
                 d.DismissalDate = s.DismissalDate, d.IsActive = s.IsActive
    FROM dbo.DimDoctor d JOIN stg.Doctor s ON s.DoctorID = d.DoctorID_Source
    WHERE EXISTS (SELECT d.LicenseNumber, d.FullName, d.FloorNumber, d.StandardConsultMinutes, d.HireDate, d.DismissalDate, d.IsActive
                  EXCEPT
                  SELECT s.LicenseNumber, s.FullName, s.FloorNumber, s.StandardConsultMinutes, s.HireDate, s.DismissalDate, s.IsActive);
    SET @Type1Updated = @@ROWCOUNT;

    DECLARE @chg TABLE (DoctorID INT PRIMARY KEY);
    INSERT INTO @chg (DoctorID)
    SELECT s.DoctorID
    FROM stg.Doctor s JOIN dbo.DimDoctor d ON d.DoctorID_Source = s.DoctorID AND d.IsCurrent = 1
    WHERE EXISTS (SELECT d.DepartmentName, d.SpecialtyName, d.QualificationCategory, d.HourlyRate
                  EXCEPT
                  SELECT s.DepartmentName, s.SpecialtyName, s.QualificationCategory, s.HourlyRate);

    UPDATE d SET d.ValidTo = @Eff, d.IsCurrent = 0
    FROM dbo.DimDoctor d JOIN @chg c ON c.DoctorID = d.DoctorID_Source
    WHERE d.IsCurrent = 1;

    INSERT INTO dbo.DimDoctor (DoctorID_Source, LicenseNumber, FullName, DepartmentName, FloorNumber, SpecialtyName, StandardConsultMinutes,
                               HourlyRate, QualificationCategory, HireDate, DismissalDate, IsActive, ValidFrom, ValidTo, IsCurrent)
    SELECT s.DoctorID, s.LicenseNumber, s.FullName, s.DepartmentName, s.FloorNumber, s.SpecialtyName, s.StandardConsultMinutes,
           s.HourlyRate, s.QualificationCategory, s.HireDate, s.DismissalDate, s.IsActive, @Eff, '9999-12-31', 1
    FROM stg.Doctor s JOIN @chg c ON c.DoctorID = s.DoctorID;
    SET @NewVersions = @@ROWCOUNT;

    INSERT INTO dbo.DimDoctor (DoctorID_Source, LicenseNumber, FullName, DepartmentName, FloorNumber, SpecialtyName, StandardConsultMinutes,
                               HourlyRate, QualificationCategory, HireDate, DismissalDate, IsActive, ValidFrom, ValidTo, IsCurrent)
    SELECT s.DoctorID, s.LicenseNumber, s.FullName, s.DepartmentName, s.FloorNumber, s.SpecialtyName, s.StandardConsultMinutes,
           s.HourlyRate, s.QualificationCategory, s.HireDate, s.DismissalDate, s.IsActive, '1900-01-01', '9999-12-31', 1
    FROM stg.Doctor s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.DimDoctor d WHERE d.DoctorID_Source = s.DoctorID);
    SET @Inserted = @@ROWCOUNT;
END;
GO

/* =====================================================================
   4. ФАКТИ — інкрементальний UPSERT зі staging
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_Load_FactVisits
    @ExecutionID INT = NULL,
    @Inserted INT = 0 OUTPUT,
    @Updated  INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @act TABLE (A NVARCHAR(10));
    MERGE dbo.FactVisits AS t
    USING stg.FactVisits AS s
       ON t.SourceSystem = s.SourceSystem AND t.DiagnosisID_Source = s.DiagnosisID_Source
    WHEN MATCHED AND EXISTS (
            SELECT s.VisitID_Source, s.DateKey, s.RecoveryDateKey, s.PatientKey, s.DoctorKey, s.DiseaseKey, s.AgeGroupKey, s.OutcomeKey,
                   s.IsPrimaryDiagnosis, s.IsFreeNSZU, s.VisitCount, s.AgeAtVisit, s.DurationMinutes, s.ConsultationCostUAH,
                   s.ConsultationCostEUR, s.TreatmentDurationDays, s.SickLeaveDays, s.IsRecoveredFlag
            EXCEPT
            SELECT t.VisitID_Source, t.DateKey, t.RecoveryDateKey, t.PatientKey, t.DoctorKey, t.DiseaseKey, t.AgeGroupKey, t.OutcomeKey,
                   t.IsPrimaryDiagnosis, t.IsFreeNSZU, t.VisitCount, t.AgeAtVisit, t.DurationMinutes, t.ConsultationCostUAH,
                   t.ConsultationCostEUR, t.TreatmentDurationDays, t.SickLeaveDays, t.IsRecoveredFlag)
        THEN UPDATE SET
            t.VisitID_Source = s.VisitID_Source, t.DateKey = s.DateKey, t.RecoveryDateKey = s.RecoveryDateKey,
            t.PatientKey = s.PatientKey, t.DoctorKey = s.DoctorKey, t.DiseaseKey = s.DiseaseKey, t.AgeGroupKey = s.AgeGroupKey,
            t.OutcomeKey = s.OutcomeKey, t.IsPrimaryDiagnosis = s.IsPrimaryDiagnosis, t.IsFreeNSZU = s.IsFreeNSZU,
            t.VisitCount = s.VisitCount, t.AgeAtVisit = s.AgeAtVisit, t.DurationMinutes = s.DurationMinutes,
            t.ConsultationCostUAH = s.ConsultationCostUAH, t.ConsultationCostEUR = s.ConsultationCostEUR,
            t.TreatmentDurationDays = s.TreatmentDurationDays, t.SickLeaveDays = s.SickLeaveDays, t.IsRecoveredFlag = s.IsRecoveredFlag,
            t.SourceUpdatedAt = s.SourceUpdatedAt, t.LoadExecutionID = @ExecutionID, t.UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (SourceSystem, VisitID_Source, DiagnosisID_Source, DateKey, RecoveryDateKey, PatientKey, DoctorKey, DiseaseKey,
                     AgeGroupKey, OutcomeKey, IsPrimaryDiagnosis, IsFreeNSZU, VisitCount, AgeAtVisit, DurationMinutes,
                     ConsultationCostUAH, ConsultationCostEUR, TreatmentDurationDays, SickLeaveDays, IsRecoveredFlag,
                     SourceUpdatedAt, LoadExecutionID)
             VALUES (s.SourceSystem, s.VisitID_Source, s.DiagnosisID_Source, s.DateKey, s.RecoveryDateKey, s.PatientKey, s.DoctorKey, s.DiseaseKey,
                     s.AgeGroupKey, s.OutcomeKey, s.IsPrimaryDiagnosis, s.IsFreeNSZU, s.VisitCount, s.AgeAtVisit, s.DurationMinutes,
                     s.ConsultationCostUAH, s.ConsultationCostEUR, s.TreatmentDurationDays, s.SickLeaveDays, s.IsRecoveredFlag,
                     s.SourceUpdatedAt, @ExecutionID)
    OUTPUT $action INTO @act;
    SELECT @Inserted = ISNULL(SUM(CASE WHEN A = 'INSERT' THEN 1 ELSE 0 END), 0),
           @Updated  = ISNULL(SUM(CASE WHEN A = 'UPDATE' THEN 1 ELSE 0 END), 0) FROM @act;
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_FactPrescriptions
    @ExecutionID INT = NULL,
    @Inserted INT = 0 OUTPUT,
    @Updated  INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @act TABLE (A NVARCHAR(10));
    MERGE dbo.FactPrescriptions AS t
    USING stg.FactPrescriptions AS s
       ON t.SourceSystem = s.SourceSystem AND t.PrescriptionID_Source = s.PrescriptionID_Source
    WHEN MATCHED AND EXISTS (
            SELECT s.DiagnosisID_Source, s.DateKey, s.PatientKey, s.DoctorKey, s.DiseaseKey, s.MedicationKey, s.AgeGroupKey, s.IsSubsidized,
                   s.QuantityPackages, s.CourseDurationDays, s.UnitPriceSnapshot, s.TotalMedicationCostUAH, s.SubsidizedAmountUAH, s.PatientPaidUAH
            EXCEPT
            SELECT t.DiagnosisID_Source, t.DateKey, t.PatientKey, t.DoctorKey, t.DiseaseKey, t.MedicationKey, t.AgeGroupKey, t.IsSubsidized,
                   t.QuantityPackages, t.CourseDurationDays, t.UnitPriceSnapshot, t.TotalMedicationCostUAH, t.SubsidizedAmountUAH, t.PatientPaidUAH)
        THEN UPDATE SET
            t.DiagnosisID_Source = s.DiagnosisID_Source, t.DateKey = s.DateKey, t.PatientKey = s.PatientKey, t.DoctorKey = s.DoctorKey,
            t.DiseaseKey = s.DiseaseKey, t.MedicationKey = s.MedicationKey, t.AgeGroupKey = s.AgeGroupKey, t.IsSubsidized = s.IsSubsidized,
            t.QuantityPackages = s.QuantityPackages, t.CourseDurationDays = s.CourseDurationDays, t.UnitPriceSnapshot = s.UnitPriceSnapshot,
            t.TotalMedicationCostUAH = s.TotalMedicationCostUAH, t.SubsidizedAmountUAH = s.SubsidizedAmountUAH, t.PatientPaidUAH = s.PatientPaidUAH,
            t.SourceUpdatedAt = s.SourceUpdatedAt, t.LoadExecutionID = @ExecutionID, t.UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (SourceSystem, PrescriptionID_Source, DiagnosisID_Source, DateKey, PatientKey, DoctorKey, DiseaseKey, MedicationKey,
                     AgeGroupKey, IsSubsidized, PrescriptionCount, QuantityPackages, CourseDurationDays, UnitPriceSnapshot,
                     TotalMedicationCostUAH, SubsidizedAmountUAH, PatientPaidUAH, SourceUpdatedAt, LoadExecutionID)
             VALUES (s.SourceSystem, s.PrescriptionID_Source, s.DiagnosisID_Source, s.DateKey, s.PatientKey, s.DoctorKey, s.DiseaseKey, s.MedicationKey,
                     s.AgeGroupKey, s.IsSubsidized, 1, s.QuantityPackages, s.CourseDurationDays, s.UnitPriceSnapshot,
                     s.TotalMedicationCostUAH, s.SubsidizedAmountUAH, s.PatientPaidUAH, s.SourceUpdatedAt, @ExecutionID)
    OUTPUT $action INTO @act;
    SELECT @Inserted = ISNULL(SUM(CASE WHEN A = 'INSERT' THEN 1 ELSE 0 END), 0),
           @Updated  = ISNULL(SUM(CASE WHEN A = 'UPDATE' THEN 1 ELSE 0 END), 0) FROM @act;
END;
GO

/* Агрегований факт: перераховуються лише місяці, яких торкнулося поточне завантаження
   (або всі — при @FullRebuild = 1). Візитні міри беруться лише з основних діагнозів (VisitCount = 1). */
CREATE OR ALTER PROCEDURE etl.usp_Rebuild_FactDoctorMonthlySummary
    @ExecutionID INT = NULL,
    @FullRebuild BIT = 0,
    @Rows INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @months TABLE (MonthKey INT PRIMARY KEY);
    IF @FullRebuild = 1
        INSERT INTO @months SELECT DISTINCT DateKey / 100 FROM dbo.FactVisits;
    ELSE
        INSERT INTO @months SELECT DISTINCT DateKey / 100 FROM stg.FactVisits;

    DELETE s FROM dbo.FactDoctorMonthlySummary s JOIN @months m ON m.MonthKey = s.MonthKey;

    ;WITH wd AS (
        SELECT MonthKey, CAST(SUM(CASE WHEN WorkingDayStatus = N'Робочий день' THEN 1 ELSE 0 END) AS TINYINT) AS WorkingDays
        FROM dbo.DimDate WHERE DateKey <> 19000101 GROUP BY MonthKey
    )
    INSERT INTO dbo.FactDoctorMonthlySummary (
        DoctorKey, MonthKey, MonthDateKey, TotalVisitsCount, UniquePatientsCount, FreeNSZUVisitsCount, TotalDurationMinutes,
        AvgVisitDurationMinutes, MinVisitDurationMinutes, MaxVisitDurationMinutes, TotalRevenueUAH, TotalSickLeaveDaysIssued,
        WorkingDaysInMonth, VisitsPerWorkingDay, LoadExecutionID)
    SELECT
        fv.DoctorKey,
        fv.DateKey / 100,
        (fv.DateKey / 100) * 100 + 1,
        SUM(fv.VisitCount),
        COUNT(DISTINCT CASE WHEN fv.VisitCount = 1 THEN fv.PatientKey END),
        SUM(CASE WHEN fv.VisitCount = 1 AND fv.IsFreeNSZU = 1 THEN 1 ELSE 0 END),
        SUM(CASE WHEN fv.VisitCount = 1 THEN fv.DurationMinutes ELSE 0 END),
        CAST(AVG(CASE WHEN fv.VisitCount = 1 THEN CAST(fv.DurationMinutes AS DECIMAL(10,2)) END) AS DECIMAL(10,2)),
        MIN(CASE WHEN fv.VisitCount = 1 THEN fv.DurationMinutes END),
        MAX(CASE WHEN fv.VisitCount = 1 THEN fv.DurationMinutes END),
        SUM(fv.ConsultationCostUAH),
        SUM(fv.SickLeaveDays),
        MAX(wd.WorkingDays),
        CAST(1.0 * SUM(fv.VisitCount) / NULLIF(MAX(wd.WorkingDays), 0) AS DECIMAL(10,2)),
        @ExecutionID
    FROM dbo.FactVisits fv
    JOIN @months m ON m.MonthKey = fv.DateKey / 100
    JOIN wd ON wd.MonthKey = fv.DateKey / 100
    GROUP BY fv.DoctorKey, fv.DateKey / 100
    HAVING SUM(fv.VisitCount) > 0;
    SET @Rows = @@ROWCOUNT;
END;
GO

/* =====================================================================
   5. ПОВНЕ ПЕРЕЗАВАНТАЖЕННЯ
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_ResetForFullLoad
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.FactDoctorMonthlySummary;
    TRUNCATE TABLE dbo.FactPrescriptions;
    TRUNCATE TABLE dbo.FactVisits;
    DELETE FROM dbo.DimPatient    WHERE PatientKey    <> -1;
    DELETE FROM dbo.DimDoctor     WHERE DoctorKey     <> -1;
    DELETE FROM dbo.DimDisease    WHERE DiseaseKey    <> -1;
    DELETE FROM dbo.DimMedication WHERE MedicationKey <> -1;
    DBCC CHECKIDENT ('dbo.DimPatient', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.DimDoctor', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.DimDisease', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.DimMedication', RESEED, 0) WITH NO_INFOMSGS;
    UPDATE etl.Watermarks SET LastLoadedValue = '1900-01-01', LastExecutionID = NULL, LastUpdated = SYSDATETIME();
    DELETE FROM etl.ProcessedFiles;
    TRUNCATE TABLE stg.Patient;    TRUNCATE TABLE stg.Doctor;     TRUNCATE TABLE stg.Disease;
    TRUNCATE TABLE stg.Medication; TRUNCATE TABLE stg.FactVisits; TRUNCATE TABLE stg.FactPrescriptions;
    TRUNCATE TABLE stg.DoctorMonthlySummary; TRUNCATE TABLE stg.ArchiveVisitRaw;
END;
GO

/* =====================================================================
   5a. ПРОЦЕДУРИ-ОБГОРТКИ ДЛЯ ПАКЕТІВ SSIS (SSIS_Projects/Polyclinic_ETL)
       Викликаються з Execute SQL Task одним рядком EXEC ... ?, ?, ...
   ===================================================================== */

-- Застосування staging-даних до виміру + запис у журнал задач
CREATE OR ALTER PROCEDURE etl.usp_SSIS_ApplyDimension
    @Dimension   NVARCHAR(50),
    @ExecutionID INT,
    @RowsRead    INT = 0,
    @TaskStart   DATETIME = NULL,
    @RowsInsertedByDataFlow INT = NULL   -- SCD1: нові рядки вставляє сам Data Flow (OLE DB Destination)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @i INT = 0, @u INT = 0, @nv INT = 0, @t1 INT = 0, @Task NVARCHAR(150), @Notes NVARCHAR(500);
    DECLARE @Eff DATETIME2(0) = SYSDATETIME();
    BEGIN TRAN;
    IF @Dimension = N'DimPatient'
    BEGIN
        EXEC etl.usp_Load_DimPatient_SCD2 @ExecutionID, @Eff, @i OUTPUT, @nv OUTPUT, @t1 OUTPUT;
        SELECT @u = @nv + @t1, @Task = N'DimPatient (SCD2, SSIS)',
               @Notes = CONCAT(N'Нових пацієнтів: ', @i, N'; нових версій SCD2: ', @nv, N'; перезаписів SCD1: ', @t1);
    END
    ELSE IF @Dimension = N'DimDoctor'
    BEGIN
        EXEC etl.usp_Load_DimDoctor_SCD2 @ExecutionID, @Eff, @i OUTPUT, @nv OUTPUT, @t1 OUTPUT;
        SELECT @u = @nv + @t1, @Task = N'DimDoctor (SCD2, SSIS)',
               @Notes = CONCAT(N'Нових лікарів: ', @i, N'; нових версій SCD2: ', @nv, N'; перезаписів SCD1: ', @t1);
    END
    ELSE IF @Dimension = N'DimDisease'
    BEGIN
        EXEC etl.usp_Load_DimDisease @ExecutionID, @i OUTPUT, @u OUTPUT;
        SELECT @Task = N'DimDisease (SCD1 update, SSIS)', @Notes = CONCAT(N'Оновлено (SCD1): ', @u);
    END
    ELSE IF @Dimension = N'DimMedication'
    BEGIN
        EXEC etl.usp_Load_DimMedication @ExecutionID, @i OUTPUT, @u OUTPUT;
        SELECT @Task = N'DimMedication (SCD1 update, SSIS)', @Notes = CONCAT(N'Оновлено (SCD1): ', @u);
    END
    ELSE
        THROW 50203, N'Невідомий вимір для etl.usp_SSIS_ApplyDimension.', 1;
    COMMIT;
    IF @RowsInsertedByDataFlow IS NOT NULL
        SELECT @i = @RowsInsertedByDataFlow, @Notes = CONCAT(N'Нових (Data Flow): ', @RowsInsertedByDataFlow, N'; ', @Notes);
    EXEC etl.usp_LogTask @ExecutionID, @Task, @RowsRead, @i, @u, 0, @TaskStart, @Notes;
END;
GO

-- Імітація збою для перевірки відновлення з checkpoint (параметр проєкту SimulateFailureAt)
CREATE OR ALTER PROCEDURE etl.usp_SSIS_CheckSimulatedFailure
    @SimulateFailureAt NVARCHAR(100),
    @PackageName       NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    IF @SimulateFailureAt IS NOT NULL AND @SimulateFailureAt = @PackageName
    BEGIN
        DECLARE @msg NVARCHAR(400) = N'Імітація збою у пакеті ' + @PackageName
            + N' (параметр SimulateFailureAt). Повторний запуск продовжить роботу з контрольної точки (checkpoint).';
        THROW 50999, @msg, 1;
    END
END;
GO

-- Застосування staging-даних до таблиці фактів (MERGE) + журнал
CREATE OR ALTER PROCEDURE etl.usp_SSIS_ApplyFact
    @Fact         NVARCHAR(50),
    @ExecutionID  INT,
    @RowsRead     INT = 0,
    @RowsRejected INT = 0,
    @TaskStart    DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i INT = 0, @u INT = 0, @Task NVARCHAR(150);
    IF @Fact = N'FactVisits'
        EXEC etl.usp_Load_FactVisits @ExecutionID, @i OUTPUT, @u OUTPUT;
    ELSE IF @Fact = N'FactPrescriptions'
        EXEC etl.usp_Load_FactPrescriptions @ExecutionID, @i OUTPUT, @u OUTPUT;
    ELSE
        THROW 50204, N'Невідома таблиця фактів для etl.usp_SSIS_ApplyFact.', 1;
    SET @Task = @Fact + N' (MERGE, SSIS)';
    EXEC etl.usp_LogTask @ExecutionID, @Task, @RowsRead, @i, @u, @RowsRejected, @TaskStart, NULL;
END;
GO

-- Агрегований факт: заміна місяців, обчислених трансформацією Aggregate (stg.DoctorMonthlySummary)
CREATE OR ALTER PROCEDURE etl.usp_SSIS_ApplyDoctorMonthly
    @ExecutionID INT,
    @FullRebuild BIT = 0,
    @RowsRead    INT = 0,
    @TaskStart   DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @r INT;
    BEGIN TRAN;
    IF @FullRebuild = 1
        DELETE FROM dbo.FactDoctorMonthlySummary;
    ELSE
        DELETE s FROM dbo.FactDoctorMonthlySummary s
        WHERE s.MonthKey IN (SELECT DISTINCT MonthKey FROM stg.DoctorMonthlySummary);
    INSERT INTO dbo.FactDoctorMonthlySummary (
        DoctorKey, MonthKey, MonthDateKey, TotalVisitsCount, UniquePatientsCount, FreeNSZUVisitsCount, TotalDurationMinutes,
        AvgVisitDurationMinutes, MinVisitDurationMinutes, MaxVisitDurationMinutes, TotalRevenueUAH, TotalSickLeaveDaysIssued,
        WorkingDaysInMonth, VisitsPerWorkingDay, LoadExecutionID)
    SELECT DoctorKey, MonthKey, MonthDateKey, TotalVisitsCount, UniquePatientsCount, FreeNSZUVisitsCount, TotalDurationMinutes,
           AvgVisitDurationMinutes, MinVisitDurationMinutes, MaxVisitDurationMinutes, TotalRevenueUAH, TotalSickLeaveDaysIssued,
           WorkingDaysInMonth, VisitsPerWorkingDay, @ExecutionID
    FROM stg.DoctorMonthlySummary;
    SET @r = @@ROWCOUNT;
    COMMIT;
    EXEC etl.usp_LogTask @ExecutionID, N'FactDoctorMonthlySummary (Aggregate, SSIS)', @RowsRead, @r, 0, 0, @TaskStart, NULL;
END;
GO

-- Архів Філії №2: реєстрація прочитаного файлу (IsLoaded = 0 до успішного MERGE)
CREATE OR ALTER PROCEDURE etl.usp_RegisterArchiveFile
    @FileName      NVARCHAR(260),
    @FileSizeBytes BIGINT,
    @RowsRead      INT,
    @ExecutionID   INT
AS
BEGIN
    SET NOCOUNT ON;
    MERGE etl.ProcessedFiles AS t
    USING (SELECT @FileName AS FileName) AS s ON t.FileName = s.FileName
    WHEN MATCHED THEN UPDATE SET FileSizeBytes = @FileSizeBytes, RowsRead = @RowsRead, RowsLoaded = 0, RowsRejected = 0,
                                 ExecutionID = @ExecutionID, ProcessedAt = SYSDATETIME(), IsLoaded = 0, LoadedAt = NULL
    WHEN NOT MATCHED THEN INSERT (FileName, FileSizeBytes, RowsRead, ExecutionID, IsLoaded)
                          VALUES (@FileName, @FileSizeBytes, @RowsRead, @ExecutionID, 0);
END;
GO

-- Дублікати RecordNo у сирих даних архіву -> карантин (самі дублікати видаляє Sort у Data Flow)
CREATE OR ALTER PROCEDURE etl.usp_QuarantineArchiveDuplicates
    @ExecutionID INT,
    @PackageName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH r AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY UPPER(LTRIM(RTRIM(RecordNo))) ORDER BY SourceFile) AS rn
        FROM stg.ArchiveVisitRaw
    )
    INSERT INTO etl.ErrorRecords (ExecutionID, PackageName, SourceSystem, SourceFile, SourceRecordID, ErrorCode, ErrorColumn, ErrorReason, RawData)
    SELECT @ExecutionID, @PackageName, N'BRANCH2', SourceFile, RecordNo, N'ERR_DUPLICATE', N'RecordNo',
           N'Повторний запис з тим самим номером (видалено трансформацією Sort)',
           LEFT(CONCAT_WS(N';', RecordNo, VisitDateTime, PatientCard, DoctorLicense, ICD10, DurationMin, CostAmount, Currency), 2000)
    FROM r WHERE rn > 1;
    SELECT @@ROWCOUNT AS DuplicateRows;
END;
GO

-- Підтвердження успішного завантаження файлів архіву поточного запуску
CREATE OR ALTER PROCEDURE etl.usp_CompleteArchiveFiles
    @ExecutionID INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE pf SET
        RowsRejected = ISNULL(e.Cnt, 0),
        RowsLoaded   = pf.RowsRead - ISNULL(e.Cnt, 0),
        IsLoaded     = 1,
        LoadedAt     = SYSDATETIME()
    FROM etl.ProcessedFiles pf
    OUTER APPLY (SELECT COUNT(*) AS Cnt FROM etl.ErrorRecords er
                 WHERE er.ExecutionID = @ExecutionID AND er.SourceFile = pf.FileName) e
    WHERE pf.ExecutionID = @ExecutionID AND pf.IsLoaded = 0;
END;
GO

-- Моніторинг: останні запуски ETL з тривалістю (для звіту та скріншотів)
CREATE OR ALTER VIEW etl.vw_ExecutionHistory
AS
SELECT l.ExecutionID, l.ParentExecutionID, l.PackageName, l.LoadType, l.ExecutionStatus,
       l.StartTime, l.EndTime, DATEDIFF(SECOND, l.StartTime, ISNULL(l.EndTime, SYSDATETIME())) AS DurationSec,
       l.RowsExtracted, l.RowsInserted, l.RowsUpdated, l.RowsRejected, l.ErrorMessage, l.UserName
FROM etl.PackageExecutionLog l;
GO

/* =====================================================================
   6. ЕТАЛОННИЙ ETL НА T-SQL (OLTP -> stg -> DW)
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_RunReferenceETL
    @LoadType NVARCHAR(20) = N'Incremental',
    @ExecutionID INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadType NOT IN (N'Full', N'Incremental')
        THROW 50202, N'@LoadType має бути Full або Incremental.', 1;

    EXEC etl.usp_StartExecution @PackageName = N'T-SQL Reference ETL', @LoadType = @LoadType, @ExecutionID = @ExecutionID OUTPUT;

    DECLARE @t0 DATETIME2(0), @r INT, @i INT, @u INT, @nv INT, @t1 INT;
    DECLARE @wmPat DATETIME2(0), @wmVis DATETIME2(0), @wmDiag DATETIME2(0), @wmRx DATETIME2(0);
    DECLARE @hiPat DATETIME2(0), @hiDoc DATETIME2(0), @hiVis DATETIME2(0), @hiDiag DATETIME2(0), @hiRx DATETIME2(0);

    BEGIN TRY
        IF @LoadType = N'Full' EXEC etl.usp_ResetForFullLoad;

        -- Межі вибірки: [watermark; максимальна мітка на момент старту]
        EXEC etl.usp_GetWatermark 'Patients',      @wmPat  OUTPUT;
        EXEC etl.usp_GetWatermark 'Visits',        @wmVis  OUTPUT;
        EXEC etl.usp_GetWatermark 'Diagnoses',     @wmDiag OUTPUT;
        EXEC etl.usp_GetWatermark 'Prescriptions', @wmRx   OUTPUT;
        SELECT @hiPat  = MAX(UpdatedAt) FROM PolyclinicOLTP.dbo.Patients;
        SELECT @hiDoc  = MAX(UpdatedAt) FROM PolyclinicOLTP.dbo.Doctors;
        SELECT @hiVis  = MAX(UpdatedAt) FROM PolyclinicOLTP.dbo.Visits;
        SELECT @hiDiag = MAX(UpdatedAt) FROM PolyclinicOLTP.dbo.Diagnoses;
        SELECT @hiRx   = MAX(CreatedAt) FROM PolyclinicOLTP.dbo.Prescriptions;

        TRUNCATE TABLE stg.Patient;    TRUNCATE TABLE stg.Doctor;   TRUNCATE TABLE stg.Disease;
        TRUNCATE TABLE stg.Medication; TRUNCATE TABLE stg.FactVisits; TRUNCATE TABLE stg.FactPrescriptions;

        /* ---------- Виміри ---------- */
        -- Хвороби (повне порівняння, ~120 рядків)
        SET @t0 = SYSDATETIME();
        INSERT INTO stg.Disease (DiseaseID, ICD10Code, ICD10Chapter, DiseaseName, DiseaseCategory, IsChronic, ChronicStatusName, ProfileSpecialtyName)
        SELECT d.DiseaseID, UPPER(LTRIM(RTRIM(d.ICD10Code))), LEFT(UPPER(LTRIM(d.ICD10Code)), 1), LTRIM(RTRIM(d.DiseaseName)),
               ISNULL(d.DiseaseCategory, N'Інше'), d.IsChronic,
               CASE WHEN d.IsChronic = 1 THEN N'Хронічне' ELSE N'Гостре' END, sp.SpecialtyName
        FROM PolyclinicOLTP.dbo.Diseases d
        JOIN PolyclinicOLTP.dbo.Specialties sp ON sp.SpecialtyID = d.ProfileSpecialtyID;
        SET @r = @@ROWCOUNT;
        EXEC etl.usp_Load_DimDisease @ExecutionID, @i OUTPUT, @u OUTPUT;
        EXEC etl.usp_LogTask @ExecutionID, N'DimDisease (SCD1)', @r, @i, @u, 0, @t0;

        -- Лікарські засоби (повне порівняння, 100 000 рядків)
        SET @t0 = SYSDATETIME();
        INSERT INTO stg.Medication (MedicationID, RegistrationCode, TradeName, ActiveSubstance, PharmacologicalGroup, ReleaseForm,
                                    Manufacturer, ManufacturerCountry, IsDomestic, UnitPrice, PriceCategory)
        SELECT m.MedicationID, m.RegistrationCode, m.TradeName, m.ActiveSubstance, m.PharmacologicalGroup, m.ReleaseForm, m.Manufacturer,
               c.Country, CASE WHEN c.Country = N'Україна' THEN 1 ELSE 0 END, m.UnitPrice,
               CASE WHEN m.UnitPrice < 200 THEN N'Бюджетний (< 200 грн)'
                    WHEN m.UnitPrice <= 800 THEN N'Середній (200–800 грн)'
                    ELSE N'Преміум (> 800 грн)' END
        FROM PolyclinicOLTP.dbo.Medications m
        CROSS APPLY (SELECT CASE WHEN CHARINDEX(N'(', m.Manufacturer) > 0
                                 THEN LEFT(SUBSTRING(m.Manufacturer, CHARINDEX(N'(', m.Manufacturer) + 1, 100),
                                           CHARINDEX(N')', SUBSTRING(m.Manufacturer, CHARINDEX(N'(', m.Manufacturer) + 1, 100) + N')') - 1)
                                 ELSE N'Невідомо' END AS Country) c;
        SET @r = @@ROWCOUNT;
        EXEC etl.usp_Load_DimMedication @ExecutionID, @i OUTPUT, @u OUTPUT;
        EXEC etl.usp_LogTask @ExecutionID, N'DimMedication (SCD1)', @r, @i, @u, 0, @t0;

        -- Лікарі (500 рядків — повне порівняння, бо ставка зберігається в Specialties)
        SET @t0 = SYSDATETIME();
        INSERT INTO stg.Doctor (DoctorID, LicenseNumber, FullName, DepartmentName, FloorNumber, SpecialtyName, StandardConsultMinutes,
                                HourlyRate, QualificationCategory, HireDate, DismissalDate, IsActive, SourceUpdatedAt)
        SELECT d.DoctorID, d.LicenseNumber, d.LastName + N' ' + d.FirstName + ISNULL(N' ' + d.MiddleName, N''),
               dep.DepartmentName, dep.FloorNumber, sp.SpecialtyName, sp.StandardConsultMinutes, sp.HourlyRate,
               d.QualificationCategory, d.HireDate, d.DismissalDate, d.IsActive, d.UpdatedAt
        FROM PolyclinicOLTP.dbo.Doctors d
        JOIN PolyclinicOLTP.dbo.Departments dep ON dep.DepartmentID = d.DepartmentID
        JOIN PolyclinicOLTP.dbo.Specialties sp ON sp.SpecialtyID = d.SpecialtyID;
        SET @r = @@ROWCOUNT;
        EXEC etl.usp_Load_DimDoctor_SCD2 @ExecutionID, NULL, @i OUTPUT, @nv OUTPUT, @t1 OUTPUT;
        SET @u = @nv + @t1;
        EXEC etl.usp_LogTask @ExecutionID, N'DimDoctor (SCD2)', @r, @i, @u, 0, @t0;

        -- Пацієнти (інкрементально за UpdatedAt)
        SET @t0 = SYSDATETIME();
        INSERT INTO stg.Patient (PatientID, MedicalCardNumber, TaxCode, FullName, BirthDate, Gender, GenderName, BloodType,
                                 DistrictName, AddressLine, Phone, RegistrationDate, SourceUpdatedAt)
        SELECT p.PatientID, p.MedicalCardNumber, ISNULL(p.TaxCode, '0000000000'),
               p.LastName + N' ' + p.FirstName + ISNULL(N' ' + p.MiddleName, N''), p.BirthDate, p.Gender,
               CASE p.Gender WHEN 'M' THEN N'Чоловіча' WHEN 'F' THEN N'Жіноча' ELSE N'Невідомо' END,
               ISNULL(CAST(p.BloodType AS NVARCHAR(15)), N'Невідомо'), p.DistrictName, p.AddressLine, p.Phone, p.RegistrationDate, p.UpdatedAt
        FROM PolyclinicOLTP.dbo.Patients p
        WHERE p.UpdatedAt > @wmPat AND p.UpdatedAt <= @hiPat;
        SET @r = @@ROWCOUNT;
        EXEC etl.usp_Load_DimPatient_SCD2 @ExecutionID, NULL, @i OUTPUT, @nv OUTPUT, @t1 OUTPUT;
        SET @u = @nv + @t1;
        EXEC etl.usp_LogTask @ExecutionID, N'DimPatient (SCD2)', @r, @i, @u, 0, @t0;

        /* ---------- Факт візитів / діагнозів ---------- */
        SET @t0 = SYSDATETIME();
        INSERT INTO stg.FactVisits (
            SourceSystem, VisitID_Source, DiagnosisID_Source, DateKey, RecoveryDateKey, PatientKey, DoctorKey, DiseaseKey,
            AgeGroupKey, OutcomeKey, IsPrimaryDiagnosis, IsFreeNSZU, VisitCount, AgeAtVisit, DurationMinutes,
            ConsultationCostUAH, ConsultationCostEUR, TreatmentDurationDays, SickLeaveDays, IsRecoveredFlag, SourceUpdatedAt)
        SELECT
            N'OLTP', v.VisitID, dg.DiagnosisID,
            YEAR(v.VisitDateTime) * 10000 + MONTH(v.VisitDateTime) * 100 + DAY(v.VisitDateTime),
            CASE WHEN dg.RecoveryDate IS NULL THEN 19000101
                 ELSE YEAR(dg.RecoveryDate) * 10000 + MONTH(dg.RecoveryDate) * 100 + DAY(dg.RecoveryDate) END,
            ISNULL(dp.PatientKey, -1), ISNULL(dd.DoctorKey, -1), ISNULL(ds.DiseaseKey, -1),
            ISNULL(ag.AgeGroupKey, -1), ISNULL(co.OutcomeKey, -1),
            dg.IsPrimary, v.IsFreeNSZU, CAST(dg.IsPrimary AS TINYINT), a.Age,
            CASE WHEN dg.IsPrimary = 1 THEN v.DurationMinutes ELSE 0 END,
            c.CostUAH,
            CAST(c.CostUAH / ISNULL(fx.UAHperEUR, 1) AS DECIMAL(10,2)),
            CASE WHEN dg.RecoveryDate IS NULL THEN 0 ELSE DATEDIFF(DAY, dg.DiagnosisDate, dg.RecoveryDate) END,
            dg.SickLeaveDays,
            CASE WHEN dg.TreatmentOutcome IN (N'Одужання', N'Покращення') THEN 1 ELSE 0 END,
            CASE WHEN dg.UpdatedAt > v.UpdatedAt THEN dg.UpdatedAt ELSE v.UpdatedAt END
        FROM PolyclinicOLTP.dbo.Visits v
        JOIN PolyclinicOLTP.dbo.Diagnoses dg ON dg.VisitID = v.VisitID
        JOIN PolyclinicOLTP.dbo.Patients p ON p.PatientID = v.PatientID
        CROSS APPLY (SELECT DATEDIFF(YEAR, p.BirthDate, v.VisitDateTime)
                          - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.BirthDate, v.VisitDateTime), p.BirthDate) > CAST(v.VisitDateTime AS DATE) THEN 1 ELSE 0 END AS Age) a
        LEFT JOIN dbo.DimPatient dp ON dp.PatientID_Source = v.PatientID AND v.VisitDateTime >= dp.ValidFrom AND v.VisitDateTime < dp.ValidTo
        LEFT JOIN dbo.DimDoctor dd ON dd.DoctorID_Source = v.DoctorID AND v.VisitDateTime >= dd.ValidFrom AND v.VisitDateTime < dd.ValidTo
        LEFT JOIN dbo.DimDisease ds ON ds.DiseaseID_Source = dg.DiseaseID
        LEFT JOIN dbo.DimAgeGroup ag ON a.Age BETWEEN ag.AgeFrom AND ag.AgeTo
        LEFT JOIN dbo.DimClinicalOutcome co ON co.VisitType = v.VisitType AND co.Severity = dg.Severity AND co.TreatmentOutcome = dg.TreatmentOutcome
        LEFT JOIN dbo.RefExchangeRate fx ON fx.YearNumber = YEAR(v.VisitDateTime)
        CROSS APPLY (SELECT CAST(CASE WHEN dg.IsPrimary = 1 AND v.IsFreeNSZU = 0
                                      THEN v.DurationMinutes / 60.0 * ISNULL(dd.HourlyRate, 0) ELSE 0 END AS DECIMAL(10,2)) AS CostUAH) c
        WHERE (dg.UpdatedAt > @wmDiag AND dg.UpdatedAt <= @hiDiag)
           OR (v.UpdatedAt  > @wmVis  AND v.UpdatedAt  <= @hiVis);
        SET @r = @@ROWCOUNT;
        EXEC etl.usp_Load_FactVisits @ExecutionID, @i OUTPUT, @u OUTPUT;
        EXEC etl.usp_LogTask @ExecutionID, N'FactVisits (MERGE)', @r, @i, @u, 0, @t0;

        /* ---------- Факт рецептів ---------- */
        SET @t0 = SYSDATETIME();
        INSERT INTO stg.FactPrescriptions (
            SourceSystem, PrescriptionID_Source, DiagnosisID_Source, DateKey, PatientKey, DoctorKey, DiseaseKey, MedicationKey,
            AgeGroupKey, IsSubsidized, QuantityPackages, CourseDurationDays, UnitPriceSnapshot,
            TotalMedicationCostUAH, SubsidizedAmountUAH, PatientPaidUAH, SourceUpdatedAt)
        SELECT
            N'OLTP', pr.PrescriptionID, dg.DiagnosisID,
            YEAR(v.VisitDateTime) * 10000 + MONTH(v.VisitDateTime) * 100 + DAY(v.VisitDateTime),
            ISNULL(dp.PatientKey, -1), ISNULL(dd.DoctorKey, -1), ISNULL(ds.DiseaseKey, -1), ISNULL(dm.MedicationKey, -1),
            ISNULL(ag.AgeGroupKey, -1), pr.IsSubsidized, pr.QuantityPackages, pr.DurationDays, ISNULL(dm.UnitPrice, 0),
            x.Total, x.Subsidy, x.Total - x.Subsidy, pr.CreatedAt
        FROM PolyclinicOLTP.dbo.Prescriptions pr
        JOIN PolyclinicOLTP.dbo.Diagnoses dg ON dg.DiagnosisID = pr.DiagnosisID
        JOIN PolyclinicOLTP.dbo.Visits v ON v.VisitID = dg.VisitID
        JOIN PolyclinicOLTP.dbo.Patients p ON p.PatientID = v.PatientID
        CROSS APPLY (SELECT DATEDIFF(YEAR, p.BirthDate, v.VisitDateTime)
                          - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.BirthDate, v.VisitDateTime), p.BirthDate) > CAST(v.VisitDateTime AS DATE) THEN 1 ELSE 0 END AS Age) a
        LEFT JOIN dbo.DimPatient dp ON dp.PatientID_Source = v.PatientID AND v.VisitDateTime >= dp.ValidFrom AND v.VisitDateTime < dp.ValidTo
        LEFT JOIN dbo.DimDoctor dd ON dd.DoctorID_Source = v.DoctorID AND v.VisitDateTime >= dd.ValidFrom AND v.VisitDateTime < dd.ValidTo
        LEFT JOIN dbo.DimDisease ds ON ds.DiseaseID_Source = dg.DiseaseID
        LEFT JOIN dbo.DimMedication dm ON dm.MedicationID_Source = pr.MedicationID
        LEFT JOIN dbo.DimAgeGroup ag ON a.Age BETWEEN ag.AgeFrom AND ag.AgeTo
        CROSS APPLY (SELECT CAST(pr.QuantityPackages * ISNULL(dm.UnitPrice, 0) AS DECIMAL(12,2)) AS Total) t
        CROSS APPLY (SELECT t.Total,
                            CAST(CASE WHEN pr.IsSubsidized = 1 THEN t.Total * 0.80 ELSE 0 END AS DECIMAL(12,2)) AS Subsidy) x
        WHERE pr.CreatedAt > @wmRx AND pr.CreatedAt <= @hiRx;
        SET @r = @@ROWCOUNT;
        EXEC etl.usp_Load_FactPrescriptions @ExecutionID, @i OUTPUT, @u OUTPUT;
        EXEC etl.usp_LogTask @ExecutionID, N'FactPrescriptions (MERGE)', @r, @i, @u, 0, @t0;

        /* ---------- Агрегований факт ---------- */
        SET @t0 = SYSDATETIME();
        DECLARE @Full BIT = CASE WHEN @LoadType = N'Full' THEN 1 ELSE 0 END;
        EXEC etl.usp_Rebuild_FactDoctorMonthlySummary @ExecutionID, @Full, @r OUTPUT;
        EXEC etl.usp_LogTask @ExecutionID, N'FactDoctorMonthlySummary (Aggregate)', @r, @r, 0, 0, @t0;

        /* ---------- Просування watermark-ів ---------- */
        EXEC etl.usp_SetWatermark 'Patients',      @hiPat,  @ExecutionID;
        EXEC etl.usp_SetWatermark 'Doctors',       @hiDoc,  @ExecutionID;
        EXEC etl.usp_SetWatermark 'Visits',        @hiVis,  @ExecutionID;
        EXEC etl.usp_SetWatermark 'Diagnoses',     @hiDiag, @ExecutionID;
        EXEC etl.usp_SetWatermark 'Prescriptions', @hiRx,   @ExecutionID;

        EXEC etl.usp_FinishExecution @ExecutionID;
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        IF XACT_STATE() <> -1
            EXEC etl.usp_FailExecution @ExecutionID, @Err;
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   7. ЗАПУСК: повне завантаження сховища та журнал
   ===================================================================== */
EXEC etl.usp_RunReferenceETL @LoadType = N'Full';
GO

SELECT TOP (1) ExecutionID, PackageName, LoadType, StartTime, EndTime, ExecutionStatus,
       DATEDIFF(SECOND, StartTime, EndTime) AS DurationSec, RowsExtracted, RowsInserted, RowsUpdated, RowsRejected
FROM etl.PackageExecutionLog ORDER BY ExecutionID DESC;

SELECT t.TaskName, t.RowsRead, t.RowsInserted, t.RowsUpdated, DATEDIFF(SECOND, t.StartTime, t.EndTime) AS DurationSec
FROM etl.TaskLog t WHERE t.ExecutionID = (SELECT MAX(ExecutionID) FROM etl.PackageExecutionLog) ORDER BY t.TaskLogID;

SELECT TableName, WatermarkColumn, LastLoadedValue FROM etl.Watermarks ORDER BY TableName;
GO
