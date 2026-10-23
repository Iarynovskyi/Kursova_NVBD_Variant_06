/* =====================================================================
   Файл: CREATE_CONSTRAINTS.sql
   Опис: Створення обмежень цілісності (DEFAULT, UNIQUE, CHECK, FK) та індексів
   ===================================================================== */

USE PolyclinicOLTP;
GO

/* ---------------------------------------------------------------------
   1. ОБМЕЖЕННЯ ЗА ЗАМОВЧУВАННЯМ (DEFAULT CONSTRAINTS)
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Specialties ADD CONSTRAINT DF_Specialties_ConsultMin DEFAULT (20) FOR StandardConsultMinutes;
ALTER TABLE dbo.Specialties ADD CONSTRAINT DF_Specialties_HourlyRate DEFAULT (500.00) FOR HourlyRate;

ALTER TABLE dbo.Doctors ADD CONSTRAINT DF_Doctors_IsActive DEFAULT (1) FOR IsActive;
ALTER TABLE dbo.Doctors ADD CONSTRAINT DF_Doctors_CreatedAt DEFAULT (SYSDATETIME()) FOR CreatedAt;
ALTER TABLE dbo.Doctors ADD CONSTRAINT DF_Doctors_UpdatedAt DEFAULT (SYSDATETIME()) FOR UpdatedAt;

ALTER TABLE dbo.Patients ADD CONSTRAINT DF_Patients_RegistrationDate DEFAULT (CAST(SYSDATETIME() AS DATE)) FOR RegistrationDate;
ALTER TABLE dbo.Patients ADD CONSTRAINT DF_Patients_UpdatedAt DEFAULT (SYSDATETIME()) FOR UpdatedAt;

ALTER TABLE dbo.Diseases ADD CONSTRAINT DF_Diseases_IsChronic DEFAULT (0) FOR IsChronic;

ALTER TABLE dbo.Visits ADD CONSTRAINT DF_Visits_VisitType DEFAULT (N'Первинний') FOR VisitType;
ALTER TABLE dbo.Visits ADD CONSTRAINT DF_Visits_Duration DEFAULT (20) FOR DurationMinutes;
ALTER TABLE dbo.Visits ADD CONSTRAINT DF_Visits_IsFreeNSZU DEFAULT (0) FOR IsFreeNSZU;
ALTER TABLE dbo.Visits ADD CONSTRAINT DF_Visits_UpdatedAt DEFAULT (SYSDATETIME()) FOR UpdatedAt;

ALTER TABLE dbo.Diagnoses ADD CONSTRAINT DF_Diagnoses_IsPrimary DEFAULT (1) FOR IsPrimary;
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT DF_Diagnoses_Outcome DEFAULT (N'В процесі') FOR TreatmentOutcome;
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT DF_Diagnoses_SickLeave DEFAULT (0) FOR SickLeaveDays;
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT DF_Diagnoses_UpdatedAt DEFAULT (SYSDATETIME()) FOR UpdatedAt;

ALTER TABLE dbo.Prescriptions ADD CONSTRAINT DF_Prescriptions_IsSubsidized DEFAULT (0) FOR IsSubsidized;
ALTER TABLE dbo.Prescriptions ADD CONSTRAINT DF_Prescriptions_CreatedAt DEFAULT (SYSDATETIME()) FOR CreatedAt;
GO

/* ---------------------------------------------------------------------
   2. ОБМЕЖЕННЯ УНІКАЛЬНОСТІ (UNIQUE CONSTRAINTS & FILTERED INDEXES)
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Departments ADD CONSTRAINT UQ_Departments_Name UNIQUE (DepartmentName);
ALTER TABLE dbo.Specialties ADD CONSTRAINT UQ_Specialties_Name UNIQUE (SpecialtyName);
ALTER TABLE dbo.Doctors ADD CONSTRAINT UQ_Doctors_LicenseNumber UNIQUE (LicenseNumber);
ALTER TABLE dbo.Patients ADD CONSTRAINT UQ_Patients_MedicalCardNumber UNIQUE (MedicalCardNumber);

CREATE UNIQUE NONCLUSTERED INDEX UQ_Patients_TaxCode 
ON dbo.Patients(TaxCode) WHERE TaxCode IS NOT NULL;

ALTER TABLE dbo.Diseases ADD CONSTRAINT UQ_Diseases_ICD10Code UNIQUE (ICD10Code);
ALTER TABLE dbo.Medications ADD CONSTRAINT UQ_Medications_RegistrationCode UNIQUE (RegistrationCode);

ALTER TABLE dbo.MedicationDiseaseContraindications 
ADD CONSTRAINT UQ_MedDiseaseContra_Pair UNIQUE (MedicationID, DiseaseID);

ALTER TABLE dbo.PatientContraindications 
ADD CONSTRAINT UQ_PatientContra_Pair UNIQUE (PatientID, MedicationID);

-- Одна хвороба фіксується в межах одного візиту лише один раз
ALTER TABLE dbo.Diagnoses
ADD CONSTRAINT UQ_Diagnoses_Visit_Disease UNIQUE (VisitID, DiseaseID);

-- У кожного візиту може бути лише ОДИН основний діагноз (фільтрований унікальний індекс)
CREATE UNIQUE NONCLUSTERED INDEX UX_Diagnoses_OnePrimaryPerVisit
ON dbo.Diagnoses(VisitID) WHERE IsPrimary = 1;
GO

/* ---------------------------------------------------------------------
   3. ПЕРЕВІРОЧНІ ОБМЕЖЕННЯ (CHECK CONSTRAINTS)
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Departments ADD CONSTRAINT CK_Departments_Floor 
    CHECK (FloorNumber BETWEEN 1 AND 15);

ALTER TABLE dbo.Specialties ADD CONSTRAINT CK_Specialties_ConsultMinutes 
    CHECK (StandardConsultMinutes BETWEEN 5 AND 120);
ALTER TABLE dbo.Specialties ADD CONSTRAINT CK_Specialties_HourlyRate 
    CHECK (HourlyRate > 0 AND HourlyRate <= 10000);

ALTER TABLE dbo.Doctors ADD CONSTRAINT CK_Doctors_Category 
    CHECK (QualificationCategory IN (N'Спеціаліст', N'Друга', N'Перша', N'Вища'));
ALTER TABLE dbo.Doctors ADD CONSTRAINT CK_Doctors_HireDate 
    CHECK (HireDate >= '1970-01-01' AND HireDate <= CAST(SYSDATETIME() AS DATE));
ALTER TABLE dbo.Doctors ADD CONSTRAINT CK_Doctors_DismissalDate
    CHECK (DismissalDate IS NULL OR DismissalDate >= HireDate);
-- Узгодженість статусу: активний лікар не має дати звільнення, звільнений — обов'язково має
ALTER TABLE dbo.Doctors ADD CONSTRAINT CK_Doctors_ActiveStatus
    CHECK ((IsActive = 1 AND DismissalDate IS NULL) OR (IsActive = 0 AND DismissalDate IS NOT NULL));

ALTER TABLE dbo.Patients ADD CONSTRAINT CK_Patients_Gender 
    CHECK (Gender IN ('M', 'F'));
ALTER TABLE dbo.Patients ADD CONSTRAINT CK_Patients_BloodType 
    CHECK (BloodType IN ('O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-') OR BloodType IS NULL);
ALTER TABLE dbo.Patients ADD CONSTRAINT CK_Patients_Dates 
    CHECK (BirthDate >= '1910-01-01' AND BirthDate <= RegistrationDate);

ALTER TABLE dbo.Medications ADD CONSTRAINT CK_Medications_UnitPrice 
    CHECK (UnitPrice > 0);
ALTER TABLE dbo.Medications ADD CONSTRAINT CK_Medications_ReleaseForm 
    CHECK (ReleaseForm IN (N'Таблетки', N'Капсули', N'Ампули', N'Сироп', N'Мазь', N'Краплі', N'Спрей', N'Порошок'));

ALTER TABLE dbo.MedicationDiseaseContraindications ADD CONSTRAINT CK_MedDiseaseContra_Severity 
    CHECK (SeverityLevel IN (N'Абсолютне', N'Відносне', N'З обережністю'));

ALTER TABLE dbo.PatientContraindications ADD CONSTRAINT CK_PatientContra_Severity 
    CHECK (SeverityLevel IN (N'Абсолютне', N'Високе', N'Помірне'));

ALTER TABLE dbo.Visits ADD CONSTRAINT CK_Visits_Type 
    CHECK (VisitType IN (N'Первинний', N'Повторний', N'Профілактичний', N'Невідкладний'));
ALTER TABLE dbo.Visits ADD CONSTRAINT CK_Visits_Duration 
    CHECK (DurationMinutes BETWEEN 5 AND 180);

ALTER TABLE dbo.Diagnoses ADD CONSTRAINT CK_Diagnoses_Severity 
    CHECK (Severity IN (N'Легка', N'Середня', N'Тяжка', N'Критична'));
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT CK_Diagnoses_Outcome 
    CHECK (TreatmentOutcome IN (N'Одужання', N'Покращення', N'Без змін', N'Ускладнення', N'Хронізація', N'Направлено в стаціонар', N'В процесі'));
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT CK_Diagnoses_RecoveryDate 
    CHECK (RecoveryDate IS NULL OR RecoveryDate >= DiagnosisDate);
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT CK_Diagnoses_SickLeave 
    CHECK (SickLeaveDays BETWEEN 0 AND 365);
-- Бізнес-правило: дата одужання відсутня тоді й лише тоді, коли лікування триває ("В процесі")
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT CK_Diagnoses_OutcomeRecovery
    CHECK ((TreatmentOutcome = N'В процесі' AND RecoveryDate IS NULL)
        OR (TreatmentOutcome <> N'В процесі' AND RecoveryDate IS NOT NULL));

ALTER TABLE dbo.Prescriptions ADD CONSTRAINT CK_Prescriptions_Duration 
    CHECK (DurationDays BETWEEN 1 AND 365);
ALTER TABLE dbo.Prescriptions ADD CONSTRAINT CK_Prescriptions_Quantity 
    CHECK (QuantityPackages BETWEEN 1 AND 50);
GO

/* ---------------------------------------------------------------------
   4. ЗОВНІШНІ КЛЮЧІ (FOREIGN KEY CONSTRAINTS)
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Doctors ADD CONSTRAINT FK_Doctors_Departments 
    FOREIGN KEY (DepartmentID) REFERENCES dbo.Departments(DepartmentID);
ALTER TABLE dbo.Doctors ADD CONSTRAINT FK_Doctors_Specialties 
    FOREIGN KEY (SpecialtyID) REFERENCES dbo.Specialties(SpecialtyID);

ALTER TABLE dbo.Diseases ADD CONSTRAINT FK_Diseases_Specialties
    FOREIGN KEY (ProfileSpecialtyID) REFERENCES dbo.Specialties(SpecialtyID);

ALTER TABLE dbo.MedicationDiseaseContraindications ADD CONSTRAINT FK_MedDiseaseContra_Medications 
    FOREIGN KEY (MedicationID) REFERENCES dbo.Medications(MedicationID);
ALTER TABLE dbo.MedicationDiseaseContraindications ADD CONSTRAINT FK_MedDiseaseContra_Diseases 
    FOREIGN KEY (DiseaseID) REFERENCES dbo.Diseases(DiseaseID);

ALTER TABLE dbo.PatientContraindications ADD CONSTRAINT FK_PatientContra_Patients 
    FOREIGN KEY (PatientID) REFERENCES dbo.Patients(PatientID);
ALTER TABLE dbo.PatientContraindications ADD CONSTRAINT FK_PatientContra_Medications 
    FOREIGN KEY (MedicationID) REFERENCES dbo.Medications(MedicationID);

ALTER TABLE dbo.Visits ADD CONSTRAINT FK_Visits_Patients 
    FOREIGN KEY (PatientID) REFERENCES dbo.Patients(PatientID);
ALTER TABLE dbo.Visits ADD CONSTRAINT FK_Visits_Doctors 
    FOREIGN KEY (DoctorID) REFERENCES dbo.Doctors(DoctorID);

ALTER TABLE dbo.Diagnoses ADD CONSTRAINT FK_Diagnoses_Visits 
    FOREIGN KEY (VisitID) REFERENCES dbo.Visits(VisitID) ON DELETE CASCADE;
ALTER TABLE dbo.Diagnoses ADD CONSTRAINT FK_Diagnoses_Diseases 
    FOREIGN KEY (DiseaseID) REFERENCES dbo.Diseases(DiseaseID);

ALTER TABLE dbo.Prescriptions ADD CONSTRAINT FK_Prescriptions_Diagnoses 
    FOREIGN KEY (DiagnosisID) REFERENCES dbo.Diagnoses(DiagnosisID) ON DELETE CASCADE;
ALTER TABLE dbo.Prescriptions ADD CONSTRAINT FK_Prescriptions_Medications 
    FOREIGN KEY (MedicationID) REFERENCES dbo.Medications(MedicationID);
GO

/* ---------------------------------------------------------------------
   5. НЕКЛАСТЕРИЗОВАНІ ІНДЕКСИ ДЛЯ ОПТИМІЗАЦІЇ ЗАПИТІВ (500K+ ЗАПИСІВ)
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IX_Visits_VisitDateTime_Doctor 
ON dbo.Visits (VisitDateTime ASC, DoctorID ASC)
INCLUDE (PatientID, DurationMinutes, IsFreeNSZU);

CREATE NONCLUSTERED INDEX IX_Visits_PatientID_Date 
ON dbo.Visits (PatientID ASC, VisitDateTime DESC)
INCLUDE (DoctorID, VisitType, DurationMinutes, IsFreeNSZU);

CREATE NONCLUSTERED INDEX IX_Visits_DoctorID_Patient 
ON dbo.Visits (DoctorID ASC, PatientID ASC)
INCLUDE (VisitDateTime);

CREATE NONCLUSTERED INDEX IX_Diagnoses_DiseaseID_Outcome 
ON dbo.Diagnoses (DiseaseID ASC, DiagnosisDate ASC)
INCLUDE (TreatmentOutcome, Severity, RecoveryDate, SickLeaveDays, VisitID);

CREATE NONCLUSTERED INDEX IX_Diagnoses_VisitID 
ON dbo.Diagnoses (VisitID ASC)
INCLUDE (DiseaseID, DiagnosisDate, IsPrimary, TreatmentOutcome);

CREATE NONCLUSTERED INDEX IX_Prescriptions_DiagnosisID 
ON dbo.Prescriptions (DiagnosisID ASC)
INCLUDE (MedicationID, QuantityPackages, DurationDays, IsSubsidized);

-- Пошук рецептів за препаратом (аналітика призначень, FK-індекс)
CREATE NONCLUSTERED INDEX IX_Prescriptions_MedicationID 
ON dbo.Prescriptions (MedicationID ASC)
INCLUDE (DiagnosisID, QuantityPackages, IsSubsidized);

-- Пошук алергій за препаратом (FK-індекс; пара PatientID+MedicationID вже покрита UNIQUE)
CREATE NONCLUSTERED INDEX IX_PatientContra_MedicationID 
ON dbo.PatientContraindications (MedicationID ASC);

CREATE NONCLUSTERED INDEX IX_Patients_LastName_FirstName 
ON dbo.Patients (LastName ASC, FirstName ASC)
INCLUDE (MedicalCardNumber, BirthDate, DistrictName, Phone);

CREATE NONCLUSTERED INDEX IX_Doctors_Department_Specialty 
ON dbo.Doctors (DepartmentID ASC, SpecialtyID ASC)
INCLUDE (LastName, FirstName, QualificationCategory, IsActive, HireDate, DismissalDate);
GO

PRINT N'Усі обмеження цілісності та індекси успішно створено.';
GO