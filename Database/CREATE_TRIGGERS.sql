/* =====================================================================
   Файл: CREATE_TRIGGERS.sql
   Опис: Створення тригерів для контролю складних бізнес-правил поліклініки
   ===================================================================== */

USE PolyclinicOLTP;
GO

/* ---------------------------------------------------------------------
   ТРИГЕР 1: Контроль протипоказань при виписці рецепта (Бізнес-правило BR-1)
   Перевіряє:
   1) Чи немає у пацієнта особистої алергії/непереносимості препарату
   2) Чи немає абсолютного протипоказання препарату до поточного діагнозу
      або будь-якої хронічної/активної хвороби цього пацієнта
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Prescriptions_CheckContraindications
ON dbo.Prescriptions
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Перевірка 1: Особиста алергія / непереносимість пацієнта
    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN dbo.Diagnoses d ON i.DiagnosisID = d.DiagnosisID
        INNER JOIN dbo.Visits v ON d.VisitID = v.VisitID
        INNER JOIN dbo.PatientContraindications pc 
            ON v.PatientID = pc.PatientID 
            AND i.MedicationID = pc.MedicationID
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50001, N'ПОМИЛКА БЕЗПЕКИ ПАЦІЄНТА: Призначення скасовано! У пацієнта зафіксована індивідуальна непереносимість (алергія) до обраного препарату.', 1;
        RETURN;
    END

    -- Перевірка 2: Медичне протипоказання препарату до хвороб пацієнта (поточних або хронічних)
    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN dbo.Diagnoses current_diag ON i.DiagnosisID = current_diag.DiagnosisID
        INNER JOIN dbo.Visits current_visit ON current_diag.VisitID = current_visit.VisitID
        -- Знаходимо всі візити та діагнози цього пацієнта
        INNER JOIN dbo.Visits all_visits ON current_visit.PatientID = all_visits.PatientID
        INNER JOIN dbo.Diagnoses all_diags ON all_visits.VisitID = all_diags.VisitID
        INNER JOIN dbo.Diseases dis ON all_diags.DiseaseID = dis.DiseaseID
        -- Перевіряємо таблицю протипоказань "Ліки <-> Хвороби"
        INNER JOIN dbo.MedicationDiseaseContraindications mdc 
            ON i.MedicationID = mdc.MedicationID 
            AND dis.DiseaseID = mdc.DiseaseID
        WHERE mdc.SeverityLevel = N'Абсолютне'
          AND (
              all_diags.DiagnosisID = current_diag.DiagnosisID -- Поточний діагноз
              OR dis.IsChronic = 1                             -- Або хронічна хвороба пацієнта
              OR all_diags.TreatmentOutcome = N'В процесі'     -- Або інша активна хвороба
          )
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50002, N'ПОМИЛКА БЕЗПЕКИ ПАЦІЄНТА: Призначення скасовано! Обраний препарат має АБСОЛЮТНЕ протипоказання до поточного або хронічного захворювання пацієнта.', 1;
        RETURN;
    END
END;
GO

/* ---------------------------------------------------------------------
   ТРИГЕР 2: Перевірка коректності дати прийому та статусу лікаря (BR-2)
   1) візит не раніше дати народження пацієнта            -> 50003
   2) візит не раніше дати прийому лікаря на роботу       -> 50004
   3) візит не пізніше дати звільнення лікаря; новий візит
      не можна записати до неактивного (звільненого) лікаря -> 50005
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Visits_ValidateBusinessRules
ON dbo.Visits
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Перевірка, чи дата візиту не менша за дату народження пацієнта
    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN dbo.Patients p ON i.PatientID = p.PatientID
        WHERE CAST(i.VisitDateTime AS DATE) < p.BirthDate
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50003, N'ПОМИЛКА ДАНИХ: Дата візиту не може бути ранішою за дату народження пацієнта.', 1;
        RETURN;
    END

    -- Перевірка, чи дата візиту не менша за дату прийому лікаря на роботу
    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN dbo.Doctors doc ON i.DoctorID = doc.DoctorID
        WHERE CAST(i.VisitDateTime AS DATE) < doc.HireDate
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50004, N'ПОМИЛКА ДАНИХ: Дата візиту не може бути ранішою за дату прийому лікаря на роботу.', 1;
        RETURN;
    END

    -- Перевірка статусу лікаря: після звільнення прийом неможливий;
    -- новий запис (INSERT) до неактивного лікаря заборонено
    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN dbo.Doctors doc ON i.DoctorID = doc.DoctorID
        WHERE (doc.DismissalDate IS NOT NULL AND CAST(i.VisitDateTime AS DATE) > doc.DismissalDate)
           OR (doc.IsActive = 0 AND NOT EXISTS (SELECT 1 FROM deleted d WHERE d.VisitID = i.VisitID))
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50005, N'ПОМИЛКА ДАНИХ: Лікар звільнений (неактивний) — запис на прийом після дати звільнення неможливий.', 1;
        RETURN;
    END
END;
GO

/* ---------------------------------------------------------------------
   ТРИГЕР 3: Дата встановлення діагнозу не може передувати даті візиту (BR-3)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Diagnoses_ValidateBusinessRules
ON dbo.Diagnoses
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN dbo.Visits v ON i.VisitID = v.VisitID
        WHERE i.DiagnosisDate < CAST(v.VisitDateTime AS DATE)
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50006, N'ПОМИЛКА ДАНИХ: Дата діагнозу не може бути ранішою за дату візиту.', 1;
        RETURN;
    END
END;
GO

/* ---------------------------------------------------------------------
   ТРИГЕРИ 4-7: Автоматичне оновлення поля UpdatedAt при UPDATE
   Забезпечує роботу інкрементального завантаження (Incremental Load) у SSIS
   для всіх таблиць, що мають watermark у сховищі (Patients, Doctors, Visits, Diagnoses)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Patients_UpdateTimestamp
ON dbo.Patients
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(UpdatedAt)
    BEGIN
        UPDATE p
        SET UpdatedAt = SYSDATETIME()
        FROM dbo.Patients p
        INNER JOIN inserted i ON p.PatientID = i.PatientID;
    END
END;
GO

CREATE OR ALTER TRIGGER dbo.TR_Doctors_UpdateTimestamp
ON dbo.Doctors
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(UpdatedAt)
    BEGIN
        UPDATE d
        SET UpdatedAt = SYSDATETIME()
        FROM dbo.Doctors d
        INNER JOIN inserted i ON d.DoctorID = i.DoctorID;
    END
END;
GO

CREATE OR ALTER TRIGGER dbo.TR_Visits_UpdateTimestamp
ON dbo.Visits
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(UpdatedAt)
    BEGIN
        UPDATE v
        SET UpdatedAt = SYSDATETIME()
        FROM dbo.Visits v
        INNER JOIN inserted i ON v.VisitID = i.VisitID;
    END
END;
GO

CREATE OR ALTER TRIGGER dbo.TR_Diagnoses_UpdateTimestamp
ON dbo.Diagnoses
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(UpdatedAt)
    BEGIN
        UPDATE d
        SET UpdatedAt = SYSDATETIME()
        FROM dbo.Diagnoses d
        INNER JOIN inserted i ON d.DiagnosisID = i.DiagnosisID;
    END
END;
GO

PRINT N'Усі тригери успішно створено.';
GO