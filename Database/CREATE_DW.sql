/* =====================================================================
   Файл: CREATE_DW.sql
   Опис: Сховище даних PolyclinicDW (Етап 3.2) — схема «зірка» + staging + аудит ETL

   Архітектура:
     dbo  — виміри (Dim*) та факти (Fact*) — модель «зірка» для OLAP-куба
     stg  — проміжні таблиці (staging), куди SSIS вивантажує очищені дані
     etl  — службові таблиці контролю якості ETL: журнал запусків, журнал задач,
            контрольні точки інкрементального завантаження (watermarks),
            карантин помилкових записів, реєстр оброблених файлів архіву

   Виміри (7):
     DimDate            — час (Рік → Квартал → Місяць → День, свята України)
     DimPatient         — пацієнти, SCD Type 2 (район, адреса) + Type 1 (ПІБ, телефон...)
     DimDoctor          — лікарі (денормалізовано з відділень і спеціальностей),
                          SCD Type 2 (відділення, спеціальність, категорія, ставка) + Type 1
     DimDisease         — хвороби МКХ-10, SCD Type 1 (Категорія → Хвороба)
     DimMedication      — лікарські засоби, SCD Type 1 (Фармгрупа → Речовина → Препарат)
     DimAgeGroup        — вікова група пацієнта на дату візиту (статичний)
     DimClinicalOutcome — junk-вимір: тип візиту × тяжкість × результат лікування
   Факти (3):
     FactVisits                — діагноз у межах візиту (джерела: OLTP + архів Філії №2)
     FactPrescriptions         — рецепти
     FactDoctorMonthlySummary  — агрегована завантаженість лікарів по місяцях
   Кожен вимір має «невідомий» член з ключем -1 (DimDate: 19000101).
   ===================================================================== */

USE master;
GO

IF DB_ID(N'PolyclinicDW') IS NOT NULL
BEGIN
    ALTER DATABASE PolyclinicDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PolyclinicDW;
END
GO

CREATE DATABASE PolyclinicDW;
GO

ALTER DATABASE PolyclinicDW SET RECOVERY SIMPLE;
GO

USE PolyclinicDW;
GO

CREATE SCHEMA stg AUTHORIZATION dbo;
GO
CREATE SCHEMA etl AUTHORIZATION dbo;
GO

/* =====================================================================
   1. КОНТРОЛЬ ЯКОСТІ ТА АУДИТ ETL (п. 3.3.1, 3.5)
   ===================================================================== */

-- 1.1 Журнал запусків пакетів (Master + дочірні пакети)
CREATE TABLE etl.PackageExecutionLog (
    ExecutionID       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PackageExecutionLog PRIMARY KEY,
    ParentExecutionID INT NULL CONSTRAINT FK_PackageExecutionLog_Parent REFERENCES etl.PackageExecutionLog(ExecutionID),
    PackageName       NVARCHAR(100) NOT NULL,
    LoadType          NVARCHAR(20)  NOT NULL CONSTRAINT DF_PEL_LoadType DEFAULT (N'Incremental'),
    StartTime         DATETIME2(0)  NOT NULL CONSTRAINT DF_PEL_StartTime DEFAULT (SYSDATETIME()),
    EndTime           DATETIME2(0)  NULL,
    ExecutionStatus   NVARCHAR(20)  NOT NULL CONSTRAINT DF_PEL_Status DEFAULT (N'Running'),
    RowsExtracted     INT NOT NULL CONSTRAINT DF_PEL_Extracted DEFAULT (0),
    RowsInserted      INT NOT NULL CONSTRAINT DF_PEL_Inserted DEFAULT (0),
    RowsUpdated       INT NOT NULL CONSTRAINT DF_PEL_Updated DEFAULT (0),
    RowsRejected      INT NOT NULL CONSTRAINT DF_PEL_Rejected DEFAULT (0),
    ErrorMessage      NVARCHAR(4000) NULL,
    MachineName       NVARCHAR(128) NOT NULL CONSTRAINT DF_PEL_Machine DEFAULT (HOST_NAME()),
    UserName          NVARCHAR(128) NOT NULL CONSTRAINT DF_PEL_User DEFAULT (SUSER_SNAME()),
    CONSTRAINT CK_PEL_Status   CHECK (ExecutionStatus IN (N'Running', N'Success', N'Failed')),
    CONSTRAINT CK_PEL_LoadType CHECK (LoadType IN (N'Full', N'Incremental'))
);

-- 1.2 Журнал окремих задач (Data Flow / Execute SQL) з кількістю оброблених рядків
CREATE TABLE etl.TaskLog (
    TaskLogID    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TaskLog PRIMARY KEY,
    ExecutionID  INT NOT NULL CONSTRAINT FK_TaskLog_Execution REFERENCES etl.PackageExecutionLog(ExecutionID),
    TaskName     NVARCHAR(150) NOT NULL,
    StartTime    DATETIME2(0) NOT NULL CONSTRAINT DF_TaskLog_Start DEFAULT (SYSDATETIME()),
    EndTime      DATETIME2(0) NULL,
    RowsRead     INT NOT NULL CONSTRAINT DF_TaskLog_Read DEFAULT (0),
    RowsInserted INT NOT NULL CONSTRAINT DF_TaskLog_Ins DEFAULT (0),
    RowsUpdated  INT NOT NULL CONSTRAINT DF_TaskLog_Upd DEFAULT (0),
    RowsRejected INT NOT NULL CONSTRAINT DF_TaskLog_Rej DEFAULT (0),
    Notes        NVARCHAR(500) NULL
);

-- 1.3 Контрольні точки інкрементального завантаження (по кожній таблиці-джерелу окремо)
CREATE TABLE etl.Watermarks (
    TableName        VARCHAR(50) NOT NULL CONSTRAINT PK_Watermarks PRIMARY KEY,
    WatermarkColumn  VARCHAR(50) NOT NULL,
    LastLoadedValue  DATETIME2(0) NOT NULL,
    LastExecutionID  INT NULL,
    LastUpdated      DATETIME2(0) NOT NULL CONSTRAINT DF_Watermarks_Updated DEFAULT (SYSDATETIME())
);
INSERT INTO etl.Watermarks (TableName, WatermarkColumn, LastLoadedValue) VALUES
    ('Patients',      'UpdatedAt', '1900-01-01'),
    ('Doctors',       'UpdatedAt', '1900-01-01'),
    ('Visits',        'UpdatedAt', '1900-01-01'),
    ('Diagnoses',     'UpdatedAt', '1900-01-01'),
    ('Prescriptions', 'CreatedAt', '1900-01-01');

-- 1.4 Карантин помилкових/відхилених записів (Error Output / Conditional Split)
CREATE TABLE etl.ErrorRecords (
    ErrorRecordID  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ErrorRecords PRIMARY KEY,
    ExecutionID    INT NULL,
    PackageName    NVARCHAR(100) NOT NULL,
    SourceSystem   NVARCHAR(20) NOT NULL,
    SourceFile     NVARCHAR(260) NULL,
    SourceRecordID NVARCHAR(50) NULL,
    ErrorCode      NVARCHAR(50) NOT NULL,
    ErrorColumn    NVARCHAR(128) NULL,
    ErrorReason    NVARCHAR(500) NOT NULL,
    RawData        NVARCHAR(2000) NULL,
    LoggedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_ErrorRecords_LoggedAt DEFAULT (SYSDATETIME())
);

-- 1.5 Реєстр оброблених файлів архіву (щоб файл не завантажувався повторно)
CREATE TABLE etl.ProcessedFiles (
    FileName      NVARCHAR(260) NOT NULL CONSTRAINT PK_ProcessedFiles PRIMARY KEY,
    FileSizeBytes BIGINT NULL,
    RowsRead      INT NOT NULL CONSTRAINT DF_PF_Read DEFAULT (0),
    RowsLoaded    INT NOT NULL CONSTRAINT DF_PF_Loaded DEFAULT (0),
    RowsRejected  INT NOT NULL CONSTRAINT DF_PF_Rejected DEFAULT (0),
    ExecutionID   INT NULL,
    ProcessedAt   DATETIME2(0) NOT NULL CONSTRAINT DF_PF_ProcessedAt DEFAULT (SYSDATETIME())
);
GO

/* =====================================================================
   2. ДОВІДКОВІ ТАБЛИЦІ СХОВИЩА
   ===================================================================== */

-- Середньорічний курс EUR (орієнтовно за даними НБУ) — для трансформації «конвертація валют»
CREATE TABLE dbo.RefExchangeRate (
    YearNumber SMALLINT NOT NULL CONSTRAINT PK_RefExchangeRate PRIMARY KEY,
    UAHperEUR  DECIMAL(10,4) NOT NULL CONSTRAINT CK_RefExchangeRate_Positive CHECK (UAHperEUR > 0),
    RateSource NVARCHAR(100) NOT NULL
);
INSERT INTO dbo.RefExchangeRate (YearNumber, UAHperEUR, RateSource) VALUES
    (2015, 24.2300, N'НБУ, середньорічний курс (орієнтовно)'),
    (2016, 28.2900, N'НБУ, середньорічний курс (орієнтовно)'),
    (2017, 30.0000, N'НБУ, середньорічний курс (орієнтовно)'),
    (2018, 32.1400, N'НБУ, середньорічний курс (орієнтовно)'),
    (2019, 28.9500, N'НБУ, середньорічний курс (орієнтовно)'),
    (2020, 30.7900, N'НБУ, середньорічний курс (орієнтовно)'),
    (2021, 32.3100, N'НБУ, середньорічний курс (орієнтовно)'),
    (2022, 33.9800, N'НБУ, середньорічний курс (орієнтовно)'),
    (2023, 39.5600, N'НБУ, середньорічний курс (орієнтовно)'),
    (2024, 43.4400, N'НБУ, середньорічний курс (орієнтовно)'),
    (2025, 47.0000, N'НБУ, середньорічний курс (орієнтовно)'),
    (2026, 48.5000, N'Прогноз для поточних завантажень');
GO

/* =====================================================================
   3. ВИМІРИ (DIMENSION TABLES)
   ===================================================================== */

-- 3.1 Часовий вимір (DimDate) — містить ієрархію Рік -> Квартал -> Місяць -> День
CREATE TABLE dbo.DimDate (
    DateKey INT NOT NULL PRIMARY KEY,             -- Формат YYYYMMDD (напр. 20240515)
    FullDate DATE NOT NULL UNIQUE,
    YearNumber SMALLINT NOT NULL,
    QuarterNumber TINYINT NOT NULL,
    QuarterName NVARCHAR(10) NOT NULL,            -- Q1, Q2, Q3, Q4
    QuarterKey INT NOT NULL,                      -- YYYYQ (напр. 20242) — унікальний ключ кварталу для ієрархії SSAS
    QuarterYearName NVARCHAR(20) NOT NULL,        -- "Q2 2024"
    MonthNumber TINYINT NOT NULL,
    MonthName NVARCHAR(20) NOT NULL,
    MonthKey INT NOT NULL,                        -- YYYYMM (напр. 202405) — ключ місяця (зв'язок з FactDoctorMonthlySummary)
    MonthYearName NVARCHAR(30) NOT NULL,          -- "Травень 2024"
    YearMonth CHAR(7) NOT NULL,                   -- YYYY-MM
    DayOfMonth TINYINT NOT NULL,
    DayOfWeekNumber TINYINT NOT NULL,             -- 1 (Пн) .. 7 (Нд)
    DayOfWeekName NVARCHAR(20) NOT NULL,
    WeekOfYear TINYINT NOT NULL,
    IsWeekend BIT NOT NULL,
    IsHoliday BIT NOT NULL,
    HolidayName NVARCHAR(100) NULL,               -- назва державного свята України
    WorkingDayStatus NVARCHAR(20) NOT NULL        -- Робочий день / Вихідний / Свято
);


-- 3.2 Вимір Пацієнтів — SCD Type 2 (DistrictName, AddressLine), SCD Type 1 (решта атрибутів)
CREATE TABLE dbo.DimPatient (
    PatientKey        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimPatient PRIMARY KEY,
    PatientID_Source  INT NOT NULL,                 -- ключ OLTP
    MedicalCardNumber VARCHAR(20) NOT NULL,          -- бізнес-ключ
    TaxCode           CHAR(10) NOT NULL,             -- очищений від NULL ('0000000000')
    FullName          NVARCHAR(160) NOT NULL,        -- SCD1
    BirthDate         DATE NOT NULL,
    BirthYear         SMALLINT NOT NULL,
    Gender            CHAR(1) NOT NULL,
    GenderName        NVARCHAR(15) NOT NULL,
    BloodType         NVARCHAR(15) NOT NULL,         -- SCD1, очищений від NULL ('Невідомо')
    DistrictName      NVARCHAR(100) NOT NULL,        -- SCD2 (ієрархія Район -> Пацієнт)
    AddressLine       NVARCHAR(250) NOT NULL,        -- SCD2
    Phone             VARCHAR(20) NOT NULL,          -- SCD1
    RegistrationDate  DATE NOT NULL,
    ValidFrom         DATETIME2(0) NOT NULL,
    ValidTo           DATETIME2(0) NOT NULL CONSTRAINT DF_DimPatient_ValidTo DEFAULT ('9999-12-31'),
    IsCurrent         BIT NOT NULL CONSTRAINT DF_DimPatient_IsCurrent DEFAULT (1),
    CONSTRAINT CK_DimPatient_Validity CHECK (ValidTo > ValidFrom)
);

-- 3.3 Вимір Лікарів — денормалізований (Departments + Specialties)
--     SCD Type 2: DepartmentName, SpecialtyName, QualificationCategory, HourlyRate; SCD Type 1: решта
CREATE TABLE dbo.DimDoctor (
    DoctorKey              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimDoctor PRIMARY KEY,
    DoctorID_Source        INT NOT NULL,
    LicenseNumber          VARCHAR(30) NOT NULL,      -- бізнес-ключ
    FullName               NVARCHAR(160) NOT NULL,    -- SCD1
    DepartmentName         NVARCHAR(100) NOT NULL,    -- SCD2 (ієрархія Відділення -> Спеціальність -> Лікар)
    FloorNumber            TINYINT NOT NULL,          -- SCD1
    SpecialtyName          NVARCHAR(100) NOT NULL,    -- SCD2
    StandardConsultMinutes TINYINT NOT NULL,          -- SCD1
    HourlyRate             DECIMAL(10,2) NOT NULL,    -- SCD2 (історична ставка для розрахунку вартості)
    QualificationCategory  NVARCHAR(30) NOT NULL,     -- SCD2
    HireDate               DATE NOT NULL,
    DismissalDate          DATE NULL,                 -- SCD1
    IsActive               BIT NOT NULL,              -- SCD1
    ValidFrom              DATETIME2(0) NOT NULL,
    ValidTo                DATETIME2(0) NOT NULL CONSTRAINT DF_DimDoctor_ValidTo DEFAULT ('9999-12-31'),
    IsCurrent              BIT NOT NULL CONSTRAINT DF_DimDoctor_IsCurrent DEFAULT (1),
    CONSTRAINT CK_DimDoctor_Validity CHECK (ValidTo > ValidFrom)
);

-- 3.4 Вимір Хвороб — SCD Type 1 (ієрархія Категорія МКХ-10 -> Хвороба)
CREATE TABLE dbo.DimDisease (
    DiseaseKey           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimDisease PRIMARY KEY,
    DiseaseID_Source     INT NOT NULL,
    ICD10Code            VARCHAR(10) NOT NULL,
    ICD10Chapter         CHAR(1) NOT NULL,             -- літера розділу МКХ-10 (Derived Column)
    DiseaseName          NVARCHAR(200) NOT NULL,
    DiseaseCategory      NVARCHAR(100) NOT NULL,
    IsChronic            BIT NOT NULL,
    ChronicStatusName    NVARCHAR(30) NOT NULL,        -- Хронічне / Гостре
    ProfileSpecialtyName NVARCHAR(100) NOT NULL
);

-- 3.5 Вимір Лікарських засобів — SCD Type 1 (ієрархія Фармгрупа -> Діюча речовина -> Препарат)
CREATE TABLE dbo.DimMedication (
    MedicationKey        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimMedication PRIMARY KEY,
    MedicationID_Source  INT NOT NULL,
    RegistrationCode     VARCHAR(30) NOT NULL,
    TradeName            NVARCHAR(150) NOT NULL,
    ActiveSubstance      NVARCHAR(150) NOT NULL,
    PharmacologicalGroup NVARCHAR(100) NOT NULL,
    ReleaseForm          NVARCHAR(50) NOT NULL,
    Manufacturer         NVARCHAR(100) NOT NULL,
    ManufacturerCountry  NVARCHAR(60) NOT NULL,        -- Derived Column: країна з назви виробника
    IsDomestic           BIT NOT NULL,                 -- вітчизняний виробник
    UnitPrice            DECIMAL(10,2) NOT NULL,
    PriceCategory        NVARCHAR(30) NOT NULL         -- Бюджетний / Середній / Преміум
);

-- 3.6 Вимір Вікових груп (статичний, вік обчислюється на дату візиту)
CREATE TABLE dbo.DimAgeGroup (
    AgeGroupKey  INT NOT NULL CONSTRAINT PK_DimAgeGroup PRIMARY KEY,
    AgeGroupName NVARCHAR(40) NOT NULL,
    AgeFrom      SMALLINT NULL,
    AgeTo        SMALLINT NULL,
    SortOrder    TINYINT NOT NULL
);
INSERT INTO dbo.DimAgeGroup (AgeGroupKey, AgeGroupName, AgeFrom, AgeTo, SortOrder) VALUES
    (-1, N'Невідомо', NULL, NULL, 0),
    (1, N'Діти та підлітки (0–17)', 0, 17, 1),
    (2, N'Молодь (18–35)', 18, 35, 2),
    (3, N'Дорослі (36–59)', 36, 59, 3),
    (4, N'Літні (60–74)', 60, 74, 4),
    (5, N'Довгожителі та старечий вік (75+)', 75, 150, 5);

-- 3.7 Junk-вимір клінічного результату: тип візиту × тяжкість × результат лікування
CREATE TABLE dbo.DimClinicalOutcome (
    OutcomeKey       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimClinicalOutcome PRIMARY KEY,
    VisitType        NVARCHAR(30) NOT NULL,
    Severity         NVARCHAR(20) NOT NULL,
    SeverityOrder    TINYINT NOT NULL,
    TreatmentOutcome NVARCHAR(30) NOT NULL,
    OutcomeGroup     NVARCHAR(30) NOT NULL,             -- Позитивний / Нейтральний / Негативний / Триває
    IsRecovered      BIT NOT NULL,                      -- Одужання або Покращення
    IsClosed         BIT NOT NULL,                      -- випадок завершено
    CONSTRAINT UQ_DimClinicalOutcome UNIQUE (VisitType, Severity, TreatmentOutcome)
);
GO

-- Невідомі члени вимірів (ключ -1) — для фактів без відповідності у вимірі
SET IDENTITY_INSERT dbo.DimPatient ON;
INSERT INTO dbo.DimPatient (PatientKey, PatientID_Source, MedicalCardNumber, TaxCode, FullName, BirthDate, BirthYear, Gender, GenderName,
                            BloodType, DistrictName, AddressLine, Phone, RegistrationDate, ValidFrom, ValidTo, IsCurrent)
VALUES (-1, -1, 'UNKNOWN', '0000000000', N'Невідомий пацієнт', '1900-01-01', 1900, 'U', N'Невідомо',
        N'Невідомо', N'Невідомо', N'Невідомо', 'n/a', '1900-01-01', '1900-01-01', '9999-12-31', 1);
SET IDENTITY_INSERT dbo.DimPatient OFF;

SET IDENTITY_INSERT dbo.DimDoctor ON;
INSERT INTO dbo.DimDoctor (DoctorKey, DoctorID_Source, LicenseNumber, FullName, DepartmentName, FloorNumber, SpecialtyName,
                           StandardConsultMinutes, HourlyRate, QualificationCategory, HireDate, DismissalDate, IsActive, ValidFrom, ValidTo, IsCurrent)
VALUES (-1, -1, 'UNKNOWN', N'Невідомий лікар', N'Невідомо', 0, N'Невідомо', 0, 0, N'Невідомо', '1900-01-01', NULL, 0, '1900-01-01', '9999-12-31', 1);
SET IDENTITY_INSERT dbo.DimDoctor OFF;

SET IDENTITY_INSERT dbo.DimDisease ON;
INSERT INTO dbo.DimDisease (DiseaseKey, DiseaseID_Source, ICD10Code, ICD10Chapter, DiseaseName, DiseaseCategory, IsChronic, ChronicStatusName, ProfileSpecialtyName)
VALUES (-1, -1, 'UNKNOWN', '?', N'Невідома хвороба', N'Невідомо', 0, N'Невідомо', N'Невідомо');
SET IDENTITY_INSERT dbo.DimDisease OFF;

SET IDENTITY_INSERT dbo.DimMedication ON;
INSERT INTO dbo.DimMedication (MedicationKey, MedicationID_Source, RegistrationCode, TradeName, ActiveSubstance, PharmacologicalGroup,
                               ReleaseForm, Manufacturer, ManufacturerCountry, IsDomestic, UnitPrice, PriceCategory)
VALUES (-1, -1, 'UNKNOWN', N'Невідомий препарат', N'Невідомо', N'Невідомо', N'Невідомо', N'Невідомо', N'Невідомо', 0, 0, N'Невідомо');
SET IDENTITY_INSERT dbo.DimMedication OFF;

SET IDENTITY_INSERT dbo.DimClinicalOutcome ON;
INSERT INTO dbo.DimClinicalOutcome (OutcomeKey, VisitType, Severity, SeverityOrder, TreatmentOutcome, OutcomeGroup, IsRecovered, IsClosed)
VALUES (-1, N'Невідомо', N'Невідомо', 0, N'Невідомо', N'Невідомо', 0, 0);
SET IDENTITY_INSERT dbo.DimClinicalOutcome OFF;

-- Повне наповнення junk-виміру всіма допустимими комбінаціями (4 × 4 × 7 = 112)
INSERT INTO dbo.DimClinicalOutcome (VisitType, Severity, SeverityOrder, TreatmentOutcome, OutcomeGroup, IsRecovered, IsClosed)
SELECT vt.VisitType, sv.Severity, sv.SeverityOrder, o.TreatmentOutcome, o.OutcomeGroup, o.IsRecovered, o.IsClosed
FROM (VALUES (N'Первинний'), (N'Повторний'), (N'Профілактичний'), (N'Невідкладний')) vt(VisitType)
CROSS JOIN (VALUES (N'Легка', 1), (N'Середня', 2), (N'Тяжка', 3), (N'Критична', 4)) sv(Severity, SeverityOrder)
CROSS JOIN (VALUES (N'Одужання', N'Позитивний', 1, 1), (N'Покращення', N'Позитивний', 1, 1), (N'Без змін', N'Нейтральний', 0, 1),
                   (N'Хронізація', N'Негативний', 0, 1), (N'Ускладнення', N'Негативний', 0, 1),
                   (N'Направлено в стаціонар', N'Негативний', 0, 1), (N'В процесі', N'Триває', 0, 0)) o(TreatmentOutcome, OutcomeGroup, IsRecovered, IsClosed)
ORDER BY vt.VisitType, sv.SeverityOrder, o.TreatmentOutcome;
GO

/* =====================================================================
   4. ТАБЛИЦІ ФАКТІВ
   ===================================================================== */

-- 4.1 Факт «Діагноз у межах візиту» (історії хвороб). Природний ключ: (SourceSystem, DiagnosisID_Source)
CREATE TABLE dbo.FactVisits (
    VisitFactKey          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactVisits PRIMARY KEY,
    SourceSystem          NVARCHAR(20) NOT NULL,        -- 'OLTP' або 'BRANCH2' (архів Філії №2)
    VisitID_Source        BIGINT NOT NULL,
    DiagnosisID_Source    BIGINT NOT NULL,
    DateKey               INT NOT NULL CONSTRAINT FK_FactVisits_Date REFERENCES dbo.DimDate(DateKey),
    RecoveryDateKey       INT NOT NULL CONSTRAINT FK_FactVisits_RecoveryDate REFERENCES dbo.DimDate(DateKey),
    PatientKey            INT NOT NULL CONSTRAINT FK_FactVisits_Patient REFERENCES dbo.DimPatient(PatientKey),
    DoctorKey             INT NOT NULL CONSTRAINT FK_FactVisits_Doctor REFERENCES dbo.DimDoctor(DoctorKey),
    DiseaseKey            INT NOT NULL CONSTRAINT FK_FactVisits_Disease REFERENCES dbo.DimDisease(DiseaseKey),
    AgeGroupKey           INT NOT NULL CONSTRAINT FK_FactVisits_AgeGroup REFERENCES dbo.DimAgeGroup(AgeGroupKey),
    OutcomeKey            INT NOT NULL CONSTRAINT FK_FactVisits_Outcome REFERENCES dbo.DimClinicalOutcome(OutcomeKey),
    IsPrimaryDiagnosis    BIT NOT NULL,
    IsFreeNSZU            BIT NOT NULL,
    -- Міри
    VisitCount            TINYINT NOT NULL,             -- 1 для основного діагнозу (кількість візитів без подвійного підрахунку)
    AgeAtVisit            SMALLINT NOT NULL,
    DurationMinutes       SMALLINT NOT NULL,
    ConsultationCostUAH   DECIMAL(10,2) NOT NULL,       -- (DurationMinutes / 60) * HourlyRate (історична ставка, SCD2)
    ConsultationCostEUR   DECIMAL(10,2) NOT NULL,       -- конвертація за курсом року візиту
    TreatmentDurationDays SMALLINT NOT NULL,
    SickLeaveDays         SMALLINT NOT NULL,
    IsRecoveredFlag       TINYINT NOT NULL,             -- 1 = Одужання / Покращення
    -- Аудит
    SourceUpdatedAt       DATETIME2(0) NULL,
    LoadExecutionID       INT NULL,
    LoadedAt              DATETIME2(0) NOT NULL CONSTRAINT DF_FactVisits_LoadedAt DEFAULT (SYSDATETIME()),
    UpdatedAt             DATETIME2(0) NULL
);

-- 4.2 Факт «Рецепт». Природний ключ: (SourceSystem, PrescriptionID_Source)
CREATE TABLE dbo.FactPrescriptions (
    PrescriptionFactKey    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactPrescriptions PRIMARY KEY,
    SourceSystem           NVARCHAR(20) NOT NULL,
    PrescriptionID_Source  BIGINT NOT NULL,
    DiagnosisID_Source     BIGINT NOT NULL,
    DateKey                INT NOT NULL CONSTRAINT FK_FactRx_Date REFERENCES dbo.DimDate(DateKey),
    PatientKey             INT NOT NULL CONSTRAINT FK_FactRx_Patient REFERENCES dbo.DimPatient(PatientKey),
    DoctorKey              INT NOT NULL CONSTRAINT FK_FactRx_Doctor REFERENCES dbo.DimDoctor(DoctorKey),
    DiseaseKey             INT NOT NULL CONSTRAINT FK_FactRx_Disease REFERENCES dbo.DimDisease(DiseaseKey),
    MedicationKey          INT NOT NULL CONSTRAINT FK_FactRx_Medication REFERENCES dbo.DimMedication(MedicationKey),
    AgeGroupKey            INT NOT NULL CONSTRAINT FK_FactRx_AgeGroup REFERENCES dbo.DimAgeGroup(AgeGroupKey),
    IsSubsidized           BIT NOT NULL,
    -- Міри
    PrescriptionCount      TINYINT NOT NULL CONSTRAINT DF_FactRx_Count DEFAULT (1),
    QuantityPackages       TINYINT NOT NULL,
    CourseDurationDays     SMALLINT NOT NULL,
    UnitPriceSnapshot      DECIMAL(10,2) NOT NULL,
    TotalMedicationCostUAH DECIMAL(12,2) NOT NULL,       -- QuantityPackages * UnitPrice
    SubsidizedAmountUAH    DECIMAL(12,2) NOT NULL,       -- компенсація «Доступні ліки»
    PatientPaidUAH         DECIMAL(12,2) NOT NULL,       -- доплата пацієнта
    -- Аудит
    SourceUpdatedAt        DATETIME2(0) NULL,
    LoadExecutionID        INT NULL,
    LoadedAt               DATETIME2(0) NOT NULL CONSTRAINT DF_FactRx_LoadedAt DEFAULT (SYSDATETIME()),
    UpdatedAt              DATETIME2(0) NULL
);

-- 4.3 Агрегований факт: завантаженість лікаря за місяць (трансформація Aggregate)
CREATE TABLE dbo.FactDoctorMonthlySummary (
    SummaryKey               INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactDoctorMonthlySummary PRIMARY KEY,
    DoctorKey                INT NOT NULL CONSTRAINT FK_FactDMS_Doctor REFERENCES dbo.DimDoctor(DoctorKey),
    MonthKey                 INT NOT NULL,             -- YYYYMM
    MonthDateKey             INT NOT NULL CONSTRAINT FK_FactDMS_Date REFERENCES dbo.DimDate(DateKey),   -- 1-ше число місяця
    TotalVisitsCount         INT NOT NULL,
    UniquePatientsCount      INT NOT NULL,
    FreeNSZUVisitsCount      INT NOT NULL,
    TotalDurationMinutes     INT NOT NULL,
    AvgVisitDurationMinutes  DECIMAL(10,2) NOT NULL,
    MinVisitDurationMinutes  SMALLINT NOT NULL,
    MaxVisitDurationMinutes  SMALLINT NOT NULL,
    TotalRevenueUAH          DECIMAL(14,2) NOT NULL,
    TotalSickLeaveDaysIssued INT NOT NULL,
    WorkingDaysInMonth       TINYINT NOT NULL,
    VisitsPerWorkingDay      DECIMAL(10,2) NOT NULL,
    LoadExecutionID          INT NULL,
    CONSTRAINT UQ_FactDMS_Doctor_Month UNIQUE (DoctorKey, MonthKey)
);
GO

/* =====================================================================
   5. STAGING (stg) — приймачі SSIS Data Flow
   ===================================================================== */
CREATE TABLE stg.Patient (
    PatientID INT NOT NULL PRIMARY KEY, MedicalCardNumber VARCHAR(20) NOT NULL, TaxCode CHAR(10) NOT NULL,
    FullName NVARCHAR(160) NOT NULL, BirthDate DATE NOT NULL, Gender CHAR(1) NOT NULL, GenderName NVARCHAR(15) NOT NULL,
    BloodType NVARCHAR(15) NOT NULL, DistrictName NVARCHAR(100) NOT NULL, AddressLine NVARCHAR(250) NOT NULL,
    Phone VARCHAR(20) NOT NULL, RegistrationDate DATE NOT NULL, SourceUpdatedAt DATETIME2(0) NOT NULL);

CREATE TABLE stg.Doctor (
    DoctorID INT NOT NULL PRIMARY KEY, LicenseNumber VARCHAR(30) NOT NULL, FullName NVARCHAR(160) NOT NULL,
    DepartmentName NVARCHAR(100) NOT NULL, FloorNumber TINYINT NOT NULL, SpecialtyName NVARCHAR(100) NOT NULL,
    StandardConsultMinutes TINYINT NOT NULL, HourlyRate DECIMAL(10,2) NOT NULL, QualificationCategory NVARCHAR(30) NOT NULL,
    HireDate DATE NOT NULL, DismissalDate DATE NULL, IsActive BIT NOT NULL, SourceUpdatedAt DATETIME2(0) NOT NULL);

CREATE TABLE stg.Disease (
    DiseaseID INT NOT NULL PRIMARY KEY, ICD10Code VARCHAR(10) NOT NULL, ICD10Chapter CHAR(1) NOT NULL,
    DiseaseName NVARCHAR(200) NOT NULL, DiseaseCategory NVARCHAR(100) NOT NULL, IsChronic BIT NOT NULL,
    ChronicStatusName NVARCHAR(30) NOT NULL, ProfileSpecialtyName NVARCHAR(100) NOT NULL);

CREATE TABLE stg.Medication (
    MedicationID INT NOT NULL PRIMARY KEY, RegistrationCode VARCHAR(30) NOT NULL, TradeName NVARCHAR(150) NOT NULL,
    ActiveSubstance NVARCHAR(150) NOT NULL, PharmacologicalGroup NVARCHAR(100) NOT NULL, ReleaseForm NVARCHAR(50) NOT NULL,
    Manufacturer NVARCHAR(100) NOT NULL, ManufacturerCountry NVARCHAR(60) NOT NULL, IsDomestic BIT NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL, PriceCategory NVARCHAR(30) NOT NULL);

-- Рядки фактів, готові до завантаження (ключі вимірів уже знайдені Lookup-ами)
CREATE TABLE stg.FactVisits (
    SourceSystem NVARCHAR(20) NOT NULL, VisitID_Source BIGINT NOT NULL, DiagnosisID_Source BIGINT NOT NULL,
    DateKey INT NOT NULL, RecoveryDateKey INT NOT NULL, PatientKey INT NOT NULL, DoctorKey INT NOT NULL, DiseaseKey INT NOT NULL,
    AgeGroupKey INT NOT NULL, OutcomeKey INT NOT NULL, IsPrimaryDiagnosis BIT NOT NULL, IsFreeNSZU BIT NOT NULL,
    VisitCount TINYINT NOT NULL, AgeAtVisit SMALLINT NOT NULL, DurationMinutes SMALLINT NOT NULL,
    ConsultationCostUAH DECIMAL(10,2) NOT NULL, ConsultationCostEUR DECIMAL(10,2) NOT NULL,
    TreatmentDurationDays SMALLINT NOT NULL, SickLeaveDays SMALLINT NOT NULL, IsRecoveredFlag TINYINT NOT NULL,
    SourceUpdatedAt DATETIME2(0) NULL,
    CONSTRAINT PK_stg_FactVisits PRIMARY KEY (SourceSystem, DiagnosisID_Source));

CREATE TABLE stg.FactPrescriptions (
    SourceSystem NVARCHAR(20) NOT NULL, PrescriptionID_Source BIGINT NOT NULL, DiagnosisID_Source BIGINT NOT NULL,
    DateKey INT NOT NULL, PatientKey INT NOT NULL, DoctorKey INT NOT NULL, DiseaseKey INT NOT NULL, MedicationKey INT NOT NULL,
    AgeGroupKey INT NOT NULL, IsSubsidized BIT NOT NULL, QuantityPackages TINYINT NOT NULL, CourseDurationDays SMALLINT NOT NULL,
    UnitPriceSnapshot DECIMAL(10,2) NOT NULL, TotalMedicationCostUAH DECIMAL(12,2) NOT NULL,
    SubsidizedAmountUAH DECIMAL(12,2) NOT NULL, PatientPaidUAH DECIMAL(12,2) NOT NULL, SourceUpdatedAt DATETIME2(0) NULL,
    CONSTRAINT PK_stg_FactPrescriptions PRIMARY KEY (SourceSystem, PrescriptionID_Source));

-- Сирі рядки CSV-архіву Філії №2 (усі поля — текст, як у файлі)
CREATE TABLE stg.ArchiveVisitRaw (
    SourceFile NVARCHAR(260) NOT NULL, RecordNo NVARCHAR(30) NULL, VisitDateTime NVARCHAR(40) NULL,
    PatientCard NVARCHAR(30) NULL, DoctorLicense NVARCHAR(40) NULL, ICD10 NVARCHAR(20) NULL, VisitType NVARCHAR(40) NULL,
    Severity NVARCHAR(40) NULL, DurationMin NVARCHAR(20) NULL, CostAmount NVARCHAR(30) NULL, Currency NVARCHAR(10) NULL,
    IsFreeNSZU NVARCHAR(10) NULL, Outcome NVARCHAR(60) NULL, RecoveryDate NVARCHAR(40) NULL, SickLeaveDays NVARCHAR(10) NULL,
    Complaints NVARCHAR(500) NULL);
GO

/* =====================================================================
   6. ІНДЕКСИ: Lookup у SSIS (SCD2 — пошук версії за датою), MERGE фактів, побудова куба
   ===================================================================== */
CREATE UNIQUE NONCLUSTERED INDEX UX_DimPatient_Source_Version ON dbo.DimPatient (PatientID_Source, ValidFrom) INCLUDE (PatientKey, ValidTo, IsCurrent, BirthDate);
CREATE UNIQUE NONCLUSTERED INDEX UX_DimPatient_Current ON dbo.DimPatient (PatientID_Source) INCLUDE (PatientKey, MedicalCardNumber, BirthDate) WHERE IsCurrent = 1;
CREATE NONCLUSTERED INDEX IX_DimPatient_Card ON dbo.DimPatient (MedicalCardNumber) INCLUDE (PatientKey, PatientID_Source, BirthDate, ValidFrom, ValidTo);
CREATE UNIQUE NONCLUSTERED INDEX UX_DimDoctor_Source_Version ON dbo.DimDoctor (DoctorID_Source, ValidFrom) INCLUDE (DoctorKey, ValidTo, IsCurrent, HourlyRate);
CREATE UNIQUE NONCLUSTERED INDEX UX_DimDoctor_Current ON dbo.DimDoctor (DoctorID_Source) INCLUDE (DoctorKey, LicenseNumber, HourlyRate) WHERE IsCurrent = 1;
CREATE NONCLUSTERED INDEX IX_DimDoctor_License ON dbo.DimDoctor (LicenseNumber) INCLUDE (DoctorKey, DoctorID_Source, HourlyRate, ValidFrom, ValidTo);
CREATE UNIQUE NONCLUSTERED INDEX UX_DimDisease_Source ON dbo.DimDisease (DiseaseID_Source) INCLUDE (DiseaseKey);
CREATE NONCLUSTERED INDEX IX_DimDisease_ICD ON dbo.DimDisease (ICD10Code) INCLUDE (DiseaseKey);
CREATE UNIQUE NONCLUSTERED INDEX UX_DimMedication_Source ON dbo.DimMedication (MedicationID_Source) INCLUDE (MedicationKey, UnitPrice);

CREATE UNIQUE NONCLUSTERED INDEX UX_FactVisits_Source ON dbo.FactVisits (SourceSystem, DiagnosisID_Source) INCLUDE (VisitFactKey);
CREATE UNIQUE NONCLUSTERED INDEX UX_FactRx_Source ON dbo.FactPrescriptions (SourceSystem, PrescriptionID_Source) INCLUDE (PrescriptionFactKey);

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactVisits
ON dbo.FactVisits (DateKey, RecoveryDateKey, PatientKey, DoctorKey, DiseaseKey, AgeGroupKey, OutcomeKey, SourceSystem, IsFreeNSZU,
                   VisitCount, DurationMinutes, ConsultationCostUAH, ConsultationCostEUR, TreatmentDurationDays, SickLeaveDays, IsRecoveredFlag);

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactPrescriptions
ON dbo.FactPrescriptions (DateKey, PatientKey, DoctorKey, DiseaseKey, MedicationKey, AgeGroupKey, IsSubsidized,
                          QuantityPackages, CourseDurationDays, TotalMedicationCostUAH, SubsidizedAmountUAH, PatientPaidUAH);
GO

/* =====================================================================
   7. НАПОВНЕННЯ ЧАСОВОГО ВИМІРУ DimDate (2015 - 2030 рр.)
      Державні свята України за ст. 73 КЗпП (з урахуванням змін 2017 та 2023 рр.):
      Великдень і Трійця — за православною пасхалією (таблиця дат)
   ===================================================================== */
SET DATEFIRST 1; -- Понеділок = 1

-- Дефолтний рядок для невідомих дат (напр. коли RecoveryDate IS NULL)
INSERT INTO dbo.DimDate (
    DateKey, FullDate, YearNumber, QuarterNumber, QuarterName, QuarterKey, QuarterYearName,
    MonthNumber, MonthName, MonthKey, MonthYearName, YearMonth, DayOfMonth, DayOfWeekNumber,
    DayOfWeekName, WeekOfYear, IsWeekend, IsHoliday, HolidayName, WorkingDayStatus
)
VALUES (
    19000101, '1900-01-01', 1900, 1, N'Q1', 19001, N'Не визначено',
    1, N'Не визначено', 190001, N'Не визначено', '1900-01', 1, 1,
    N'Не визначено', 1, 0, 0, NULL, N'Не визначено'
);

DECLARE @Easter TABLE (Y INT PRIMARY KEY, EasterDate DATE NOT NULL);
INSERT INTO @Easter VALUES
    (2015,'2015-04-12'),(2016,'2016-05-01'),(2017,'2017-04-16'),(2018,'2018-04-08'),
    (2019,'2019-04-28'),(2020,'2020-04-19'),(2021,'2021-05-02'),(2022,'2022-04-24'),
    (2023,'2023-04-16'),(2024,'2024-05-05'),(2025,'2025-04-20'),(2026,'2026-04-12'),
    (2027,'2027-05-02'),(2028,'2028-04-16'),(2029,'2029-04-08'),(2030,'2030-04-28');

DECLARE @Holidays TABLE (D DATE PRIMARY KEY, HolidayName NVARCHAR(100) NOT NULL);
INSERT INTO @Holidays (D, HolidayName)
SELECT d, MIN(n) FROM (
    SELECT DATEFROMPARTS(Y, 1, 1)  AS d, N'Новий рік' AS n FROM @Easter
    UNION ALL SELECT DATEFROMPARTS(Y, 1, 7),  N'Різдво Христове (за юліанським календарем)' FROM @Easter WHERE Y <= 2023
    UNION ALL SELECT DATEFROMPARTS(Y, 3, 8),  N'Міжнародний жіночий день' FROM @Easter
    UNION ALL SELECT EasterDate,                N'Великдень' FROM @Easter
    UNION ALL SELECT DATEADD(DAY, 49, EasterDate), N'Трійця' FROM @Easter
    UNION ALL SELECT DATEFROMPARTS(Y, 5, 1),  N'День праці' FROM @Easter
    UNION ALL SELECT DATEFROMPARTS(Y, 5, 2),  N'День праці' FROM @Easter WHERE Y <= 2017
    UNION ALL SELECT DATEFROMPARTS(Y, 5, 9),  N'День перемоги над нацизмом у Другій світовій війні' FROM @Easter WHERE Y <= 2022
    UNION ALL SELECT DATEFROMPARTS(Y, 5, 8),  N'День пам''яті та перемоги над нацизмом' FROM @Easter WHERE Y >= 2023
    UNION ALL SELECT DATEFROMPARTS(Y, 6, 28), N'День Конституції України' FROM @Easter
    UNION ALL SELECT DATEFROMPARTS(Y, 8, 24), N'День Незалежності України' FROM @Easter
    UNION ALL SELECT DATEFROMPARTS(Y, 10, 14), N'День захисника України' FROM @Easter WHERE Y <= 2022
    UNION ALL SELECT DATEFROMPARTS(Y, 10, 1), N'День захисників і захисниць України' FROM @Easter WHERE Y >= 2023
    UNION ALL SELECT DATEFROMPARTS(Y, 12, 25), N'Різдво Христове' FROM @Easter WHERE Y >= 2017
) h
GROUP BY d;

;WITH DateSequence AS (
    SELECT CAST('2015-01-01' AS DATE) AS d
    UNION ALL
    SELECT DATEADD(DAY, 1, d)
    FROM DateSequence
    WHERE d < '2030-12-31'
)
INSERT INTO dbo.DimDate (
    DateKey, FullDate, YearNumber, QuarterNumber, QuarterName, QuarterKey, QuarterYearName,
    MonthNumber, MonthName, MonthKey, MonthYearName, YearMonth, DayOfMonth, DayOfWeekNumber,
    DayOfWeekName, WeekOfYear, IsWeekend, IsHoliday, HolidayName, WorkingDayStatus
)
SELECT
    YEAR(ds.d) * 10000 + MONTH(ds.d) * 100 + DAY(ds.d) AS DateKey,
    ds.d AS FullDate,
    YEAR(ds.d) AS YearNumber,
    DATEPART(QUARTER, ds.d) AS QuarterNumber,
    N'Q' + CAST(DATEPART(QUARTER, ds.d) AS NVARCHAR(2)) AS QuarterName,
    YEAR(ds.d) * 10 + DATEPART(QUARTER, ds.d) AS QuarterKey,
    N'Q' + CAST(DATEPART(QUARTER, ds.d) AS NVARCHAR(2)) + N' ' + CAST(YEAR(ds.d) AS NVARCHAR(4)) AS QuarterYearName,
    MONTH(ds.d) AS MonthNumber,
    mn.MonthName,
    YEAR(ds.d) * 100 + MONTH(ds.d) AS MonthKey,
    mn.MonthName + N' ' + CAST(YEAR(ds.d) AS NVARCHAR(4)) AS MonthYearName,
    CONVERT(CHAR(7), ds.d, 126) AS YearMonth,
    DAY(ds.d) AS DayOfMonth,
    DATEPART(WEEKDAY, ds.d) AS DayOfWeekNumber,
    CHOOSE(DATEPART(WEEKDAY, ds.d),
        N'Понеділок', N'Вівторок', N'Середа', N'Четвер', N'П''ятниця', N'Субота', N'Неділя'
    ) AS DayOfWeekName,
    DATEPART(ISO_WEEK, ds.d) AS WeekOfYear,
    CASE WHEN DATEPART(WEEKDAY, ds.d) IN (6, 7) THEN 1 ELSE 0 END AS IsWeekend,
    CASE WHEN h.D IS NOT NULL THEN 1 ELSE 0 END AS IsHoliday,
    h.HolidayName,
    -- Узгоджено з IsHoliday: свято має пріоритет над вихідним
    CASE
        WHEN h.D IS NOT NULL THEN N'Свято'
        WHEN DATEPART(WEEKDAY, ds.d) IN (6, 7) THEN N'Вихідний'
        ELSE N'Робочий день'
    END AS WorkingDayStatus
FROM DateSequence ds
LEFT JOIN @Holidays h ON h.D = ds.d
CROSS APPLY (SELECT CHOOSE(MONTH(ds.d),
        N'Січень', N'Лютий', N'Березень', N'Квітень', N'Травень', N'Червень',
        N'Липень', N'Серпень', N'Вересень', N'Жовтень', N'Листопад', N'Грудень') AS MonthName) mn
OPTION (MAXRECURSION 0);
GO


PRINT N'Сховище PolyclinicDW створено: 7 вимірів, 3 факти, staging (stg) та аудит ETL (etl).';
GO
