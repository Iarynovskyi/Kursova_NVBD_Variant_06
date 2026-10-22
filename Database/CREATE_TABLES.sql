/* =====================================================================
   Файл: CREATE_TABLES.sql
   Опис: Створення таблиць БД "Поліклініка" (3НФ) та первинних ключів
   ===================================================================== */

USE PolyclinicOLTP;
GO

-- Видалення таблиць у зворотному порядку залежностей (якщо скрипт запускається повторно)
DROP TABLE IF EXISTS dbo.Prescriptions;
DROP TABLE IF EXISTS dbo.Diagnoses;
DROP TABLE IF EXISTS dbo.Visits;
DROP TABLE IF EXISTS dbo.PatientContraindications;
DROP TABLE IF EXISTS dbo.MedicationDiseaseContraindications;
DROP TABLE IF EXISTS dbo.Medications;
DROP TABLE IF EXISTS dbo.Diseases;
DROP TABLE IF EXISTS dbo.Patients;
DROP TABLE IF EXISTS dbo.Doctors;
DROP TABLE IF EXISTS dbo.Specialties;
DROP TABLE IF EXISTS dbo.Departments;
GO

-- 1. Відділення поліклініки
CREATE TABLE dbo.Departments (
    DepartmentID INT IDENTITY(1,1) NOT NULL,
    DepartmentName NVARCHAR(100) NOT NULL,
    FloorNumber TINYINT NOT NULL,
    Phone VARCHAR(20) NULL,
    CONSTRAINT PK_Departments PRIMARY KEY CLUSTERED (DepartmentID)
);

-- 2. Спеціалізації лікарів
CREATE TABLE dbo.Specialties (
    SpecialtyID INT IDENTITY(1,1) NOT NULL,
    SpecialtyName NVARCHAR(100) NOT NULL,
    StandardConsultMinutes TINYINT NOT NULL,
    CONSTRAINT PK_Specialties PRIMARY KEY CLUSTERED (SpecialtyID)
);

-- 3. Лікарі
CREATE TABLE dbo.Doctors (
    DoctorID INT IDENTITY(1,1) NOT NULL,
    DepartmentID INT NOT NULL,
    SpecialtyID INT NOT NULL,
    LicenseNumber VARCHAR(30) NOT NULL,
    LastName NVARCHAR(50) NOT NULL,
    FirstName NVARCHAR(50) NOT NULL,
    MiddleName NVARCHAR(50) NULL,
    QualificationCategory NVARCHAR(30) NOT NULL,
    HireDate DATE NOT NULL,
    IsActive BIT NOT NULL,
    CreatedAt DATETIME2(0) NOT NULL,
    UpdatedAt DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Doctors PRIMARY KEY CLUSTERED (DoctorID)
);

-- 4. Пацієнти (мін. 50 000 записів)
CREATE TABLE dbo.Patients (
    PatientID INT IDENTITY(1,1) NOT NULL,
    MedicalCardNumber VARCHAR(20) NOT NULL,
    TaxCode CHAR(10) NULL,
    LastName NVARCHAR(50) NOT NULL,
    FirstName NVARCHAR(50) NOT NULL,
    MiddleName NVARCHAR(50) NULL,
    BirthDate DATE NOT NULL,
    Gender CHAR(1) NOT NULL,
    BloodType VARCHAR(5) NULL,
    DistrictName NVARCHAR(100) NOT NULL,
    AddressLine NVARCHAR(250) NOT NULL,
    Phone VARCHAR(20) NOT NULL,
    RegistrationDate DATE NOT NULL,
    UpdatedAt DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Patients PRIMARY KEY CLUSTERED (PatientID)
);

-- 5. Хвороби (Довідник МКХ-10)
CREATE TABLE dbo.Diseases (
    DiseaseID INT IDENTITY(1,1) NOT NULL,
    ICD10Code VARCHAR(10) NOT NULL,
    DiseaseName NVARCHAR(200) NOT NULL,
    DiseaseCategory NVARCHAR(100) NOT NULL,
    IsChronic BIT NOT NULL,
    CONSTRAINT PK_Diseases PRIMARY KEY CLUSTERED (DiseaseID)
);

-- 6. Лікарства (Довідник медикаментів)
CREATE TABLE dbo.Medications (
    MedicationID INT IDENTITY(1,1) NOT NULL,
    RegistrationCode VARCHAR(30) NOT NULL,
    TradeName NVARCHAR(150) NOT NULL,
    ActiveSubstance NVARCHAR(150) NOT NULL,
    PharmacologicalGroup NVARCHAR(100) NOT NULL,
    ReleaseForm NVARCHAR(50) NOT NULL,
    Manufacturer NVARCHAR(100) NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL,
    CONSTRAINT PK_Medications PRIMARY KEY CLUSTERED (MedicationID)
);

-- 7. Загальні медичні протипоказання (Ліки <-> Хвороби)
CREATE TABLE dbo.MedicationDiseaseContraindications (
    ContraindicationID INT IDENTITY(1,1) NOT NULL,
    MedicationID INT NOT NULL,
    DiseaseID INT NOT NULL,
    SeverityLevel NVARCHAR(20) NOT NULL,
    Notes NVARCHAR(300) NULL,
    CONSTRAINT PK_MedicationDiseaseContraindications PRIMARY KEY CLUSTERED (ContraindicationID)
);

-- 8. Особисті протипоказання та алергії пацієнтів (Пацієнти <-> Ліки)
CREATE TABLE dbo.PatientContraindications (
    PatientContraID INT IDENTITY(1,1) NOT NULL,
    PatientID INT NOT NULL,
    MedicationID INT NOT NULL,
    ReactionType NVARCHAR(100) NOT NULL,
    SeverityLevel NVARCHAR(20) NOT NULL,
    DiscoveredDate DATE NOT NULL,
    CONSTRAINT PK_PatientContraindications PRIMARY KEY CLUSTERED (PatientContraID)
);

-- 9. Амбулаторні прийоми / Візити (500 000+ записів за 10 років)
CREATE TABLE dbo.Visits (
    VisitID BIGINT IDENTITY(1,1) NOT NULL,
    PatientID INT NOT NULL,
    DoctorID INT NOT NULL,
    VisitDateTime DATETIME2(0) NOT NULL,
    VisitType NVARCHAR(30) NOT NULL,
    DurationMinutes SMALLINT NOT NULL,
    ConsultationCost DECIMAL(10,2) NOT NULL,
    Complaints NVARCHAR(500) NULL,
    UpdatedAt DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Visits PRIMARY KEY CLUSTERED (VisitID)
);

-- 10. Історії хвороб / Діагнози (мін. 500 000 записів)
CREATE TABLE dbo.Diagnoses (
    DiagnosisID BIGINT IDENTITY(1,1) NOT NULL,
    VisitID BIGINT NOT NULL,
    DiseaseID INT NOT NULL,
    DiagnosisDate DATE NOT NULL,
    IsPrimary BIT NOT NULL,
    Severity NVARCHAR(20) NOT NULL,
    TreatmentOutcome NVARCHAR(30) NOT NULL,
    RecoveryDate DATE NULL,
    SickLeaveDays SMALLINT NOT NULL,
    UpdatedAt DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Diagnoses PRIMARY KEY CLUSTERED (DiagnosisID)
);

-- 11. Призначення ліків / Рецепти
CREATE TABLE dbo.Prescriptions (
    PrescriptionID BIGINT IDENTITY(1,1) NOT NULL,
    DiagnosisID BIGINT NOT NULL,
    MedicationID INT NOT NULL,
    DailyDosage NVARCHAR(50) NOT NULL,
    DurationDays SMALLINT NOT NULL,
    QuantityPackages TINYINT NOT NULL,
    IsSubsidized BIT NOT NULL,
    CreatedAt DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Prescriptions PRIMARY KEY CLUSTERED (PrescriptionID)
);
GO

PRINT N'Усі 11 таблиць успішно створено.';
GO