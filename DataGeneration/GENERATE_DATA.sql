/* =====================================================================
   Файл: GENERATE_DATA.sql
   Опис: Масова генерація реалістичних даних (Етап 2) для Варіанту №6 "Поліклініка"
   Обсяг: ~1.92 млн записів за 10 років (2016 - 2025 рр.)
   Особливості: 
   - Строга узгодженість статі, імені та по батькові для Doctors і Patients
   - Тарифікація HourlyRate у Specialties та фіксація часу в Visits (3НФ)
   - Висока варіативність даних через Prime Modulo
   ===================================================================== */

USE PolyclinicOLTP;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

PRINT N'=== ПОЧАТОК ГЕНЕРАЦІЇ ДАНИХ ДЛЯ БАЗИ PolyclinicOLTP ===';

-- Трекер часу виконання скрипта (зберігається між пакетами GO)
DROP TABLE IF EXISTS #ScriptTimer;
CREATE TABLE #ScriptTimer (StartTime DATETIME2);
INSERT INTO #ScriptTimer VALUES (SYSDATETIME());
GO

/* ---------------------------------------------------------------------
   КРОК 0. Тимчасове вимкнення тригерів та очищення таблиць
   --------------------------------------------------------------------- */
DISABLE TRIGGER ALL ON dbo.Prescriptions;
DISABLE TRIGGER ALL ON dbo.Visits;
DISABLE TRIGGER ALL ON dbo.Patients;
DISABLE TRIGGER ALL ON dbo.Diagnoses;

DELETE FROM dbo.Prescriptions;
DELETE FROM dbo.Diagnoses;
DELETE FROM dbo.Visits;
DELETE FROM dbo.PatientContraindications;
DELETE FROM dbo.MedicationDiseaseContraindications;
DELETE FROM dbo.Medications;
DELETE FROM dbo.Diseases;
DELETE FROM dbo.Patients;
DELETE FROM dbo.Doctors;
DELETE FROM dbo.Specialties;
DELETE FROM dbo.Departments;
GO

/* ---------------------------------------------------------------------
   КРОК 1. Створення таблиці чисел #Numbers (600 000 рядків)
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS #Numbers;
CREATE TABLE #Numbers (n INT NOT NULL PRIMARY KEY CLUSTERED);

;WITH
    L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
    L1 AS (SELECT 1 AS c FROM L0 AS A CROSS JOIN L0 AS B),
    L2 AS (SELECT 1 AS c FROM L1 AS A CROSS JOIN L1 AS B),
    L3 AS (SELECT 1 AS c FROM L2 AS A CROSS JOIN L2 AS B),
    L4 AS (SELECT 1 AS c FROM L3 AS A CROSS JOIN L3 AS B),
    L5 AS (SELECT 1 AS c FROM L4 AS A CROSS JOIN L4 AS B),
    Nums AS (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM L5)
INSERT INTO #Numbers WITH (TABLOCK) (n)
SELECT TOP (600000) n FROM Nums ORDER BY n;

PRINT N'1. Допоміжну таблицю чисел (600 000) створено.';
GO

/* ---------------------------------------------------------------------
   КРОК 2. Заповнення Departments (12) та Specialties (20 з HourlyRate)
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Departments ON;
INSERT INTO dbo.Departments (DepartmentID, DepartmentName, FloorNumber, Phone)
VALUES
    (1,  N'Терапевтичне відділення №1', 1, '+380322401001'),
    (2,  N'Терапевтичне відділення №2', 2, '+380322401002'),
    (3,  N'Кардіологічне відділення', 3, '+380322401003'),
    (4,  N'Неврологічне відділення', 3, '+380322401004'),
    (5,  N'Хірургічне відділення', 4, '+380322401005'),
    (6,  N'Травматологічне відділення', 1, '+380322401006'),
    (7,  N'Офтальмологічне відділення', 2, '+380322401007'),
    (8,  N'Отоларингологічне (ЛОР) відділення', 2, '+380322401008'),
    (9,  N'Гастроентерологічне відділення', 4, '+380322401009'),
    (10, N'Ендокринологічне відділення', 5, '+380322401010'),
    (11, N'Пульмонологічне відділення', 5, '+380322401011'),
    (12, N'Відділення профілактичних оглядів', 1, '+380322401012');
SET IDENTITY_INSERT dbo.Departments OFF;

SET IDENTITY_INSERT dbo.Specialties ON;
INSERT INTO dbo.Specialties (SpecialtyID, SpecialtyName, StandardConsultMinutes, HourlyRate)
VALUES
    (1,  N'Терапевт', 20, 450.00),
    (2,  N'Сімейний лікар', 20, 420.00),
    (3,  N'Кардіолог', 30, 700.00),
    (4,  N'Невролог', 30, 680.00),
    (5,  N'Хірург', 25, 900.00),
    (6,  N'Травматолог-ортопед', 25, 850.00),
    (7,  N'Офтальмолог', 20, 600.00),
    (8,  N'Отоларинголог (ЛОР)', 20, 580.00),
    (9,  N'Гастроентеролог', 30, 650.00),
    (10, N'Ендокринолог', 30, 660.00),
    (11, N'Пульмонолог', 30, 640.00),
    (12, N'Дерматовенеролог', 20, 550.00),
    (13, N'Уролог', 25, 720.00),
    (14, N'Гінеколог', 30, 750.00),
    (15, N'Ревматолог', 30, 670.00),
    (16, N'Алерголог-імунолог', 30, 690.00),
    (17, N'Інфекціоніст', 25, 620.00),
    (18, N'Нефролог', 30, 710.00),
    (19, N'Гематолог', 35, 800.00),
    (20, N'Онколог', 40, 950.00);
SET IDENTITY_INSERT dbo.Specialties OFF;

PRINT N'2. Довідники Departments (12) та Specialties (20) заповнено.';
GO

/* ---------------------------------------------------------------------
   КРОК 3. Генерація таблиці Doctors (500 лікарів)
   Строга відповідність статі: n % 2 = 1 -> Чоловік, n % 2 = 0 -> Жінка
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Doctors ON;
INSERT INTO dbo.Doctors WITH (TABLOCK) (
    DoctorID, DepartmentID, SpecialtyID, LicenseNumber,
    LastName, FirstName, MiddleName,
    QualificationCategory, HireDate, IsActive, CreatedAt, UpdatedAt
)
SELECT 
    n AS DoctorID,
    1 + ((n - 1) % 12) AS DepartmentID,
    1 + ((n - 1) % 20) AS SpecialtyID,
    'LIC-UA-' + RIGHT('000000' + CAST(n AS VARCHAR(10)), 6) AS LicenseNumber,
    CHOOSE(1 + ((n * 31) % 30),
        N'Коваленко', N'Шевченко', N'Бойко', N'Ткаченко', N'Кравченко',
        N'Олійник', N'Шевчук', N'Поліщук', N'Бондаренко', N'Мельник',
        N'Лисенко', N'Марченко', N'Савченко', N'Руденко', N'Петренко',
        N'Клименко', N'Павленко', N'Кузьменко', N'Романенко', N'Левченко',
        N'Гончаренко', N'Василенко', N'Сидоренко', N'Кириленко', N'Романюк',
        N'Панченко', N'Гриценко', N'Ільченко', N'Юрченко', N'Симоненко'
    ) AS LastName,
    -- Ім'я строго за статтю (n % 2)
    CASE WHEN n % 2 = 1
        THEN CHOOSE(1 + ((n * 17) % 15),
            N'Олександр', N'Іван', N'Максим', N'Андрій', N'Дмитро',
            N'Сергій', N'Володимир', N'Богдан', N'Артем', N'Ігор',
            N'Михайло', N'Олег', N'Роман', N'Тарас', N'Юрій'
        )
        ELSE CHOOSE(1 + ((n * 17) % 15),
            N'Олена', N'Наталія', N'Ірина', N'Тетяна', N'Оксана',
            N'Марія', N'Вікторія', N'Юлія', N'Анна', N'Галина',
            N'Катерина', N'Леся', N'Надія', N'Ольга', N'Софія'
        )
    END AS FirstName,
    -- По батькові строго за статтю (n % 2)
    CASE WHEN n % 2 = 1
        THEN CHOOSE(1 + ((n * 23) % 15),
            N'Олександрович', N'Іванович', N'Петрович', N'Миколайович', N'Васильович',
            N'Андрійович', N'Богданович', N'Вікторович', N'Ігорович', N'Олегович',
            N'Романович', N'Сергійович', N'Володимирович', N'Михайлович', N'Тарасович'
        )
        ELSE CHOOSE(1 + ((n * 23) % 15),
            N'Олександрівна', N'Іванівна', N'Петрівна', N'Миколаївна', N'Василівна',
            N'Андріївна', N'Богданівна', N'Вікторівна', N'Ігорівна', N'Олегівна',
            N'Романівна', N'Сергіївна', N'Володимирівна', N'Михайлівна', N'Тарасівна'
        )
    END AS MiddleName,
    CHOOSE(1 + (n % 4), N'Спеціаліст', N'Друга', N'Перша', N'Вища') AS QualificationCategory,
    DATEADD(DAY, (n * 11) % 5500, CAST('2000-01-01' AS DATE)) AS HireDate,
    CASE WHEN n % 25 = 0 THEN 0 ELSE 1 END AS IsActive,
    CAST('2015-01-01 09:00:00' AS DATETIME2(0)) AS CreatedAt,
    SYSDATETIME() AS UpdatedAt
FROM #Numbers
WHERE n <= 500;
SET IDENTITY_INSERT dbo.Doctors OFF;

PRINT N'3. Таблицю Doctors (500 лікарів) згенеровано.';
GO

/* ---------------------------------------------------------------------
   КРОК 4. Генерація таблиці Patients (60 000 пацієнтів)
   Строга відповідність статі: n % 2 = 1 -> 'M' (Чоловік), n % 2 = 0 -> 'F' (Жінка)
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Patients ON;
INSERT INTO dbo.Patients WITH (TABLOCK) (
    PatientID, MedicalCardNumber, TaxCode,
    LastName, FirstName, MiddleName,
    BirthDate, Gender, BloodType,
    DistrictName, AddressLine, Phone,
    RegistrationDate, UpdatedAt
)
SELECT 
    n AS PatientID,
    'MC-' + RIGHT('0000000' + CAST(n AS VARCHAR(10)), 7) AS MedicalCardNumber,
    CASE 
        WHEN n % 20 = 0 THEN NULL 
        ELSE RIGHT('0000000000' + CAST(2500000000 + CAST(n AS BIGINT) AS VARCHAR(10)), 10) 
    END AS TaxCode,
    -- 40 українських прізвищ (нейтральні за родом на -ко, -ук, -юк, -ар, -оз)
    CHOOSE(1 + ((n * 7919) % 40),
        N'Мельник', N'Шевченко', N'Коваленко', N'Бондаренко', N'Бойко',
        N'Ткаченко', N'Кравченко', N'Ковальчук', N'Коваль', N'Олійник',
        N'Шевчук', N'Поліщук', N'Бондар', N'Ткачук', N'Мороз',
        N'Марченко', N'Лисенко', N'Руденко', N'Савченко', N'Петренко',
        N'Гончаренко', N'Василенко', N'Мазур', N'Сидоренко', N'Кириленко',
        N'Романюк', N'Панченко', N'Гриценко', N'Павленко', N'Климчук',
        N'Кузьменко', N'Ільченко', N'Юрченко', N'Степанюк', N'Симоненко',
        N'Левченко', N'Демченко', N'Яцюк', N'Волошин', N'Хоменко'
    ) AS LastName,
    -- Чоловічі (n % 2 = 1) та Жіночі (n % 2 = 0) імена
    CASE WHEN n % 2 = 1 
        THEN CHOOSE(1 + ((n * 6733) % 20),
            N'Олександр', N'Іван', N'Максим', N'Андрій', N'Дмитро',
            N'Сергій', N'Володимир', N'Богдан', N'Артем', N'Владислав',
            N'Данило', N'Ігор', N'Михайло', N'Назар', N'Олег',
            N'Павло', N'Роман', N'Тарас', N'Юрій', N'Денис'
        )
        ELSE CHOOSE(1 + ((n * 6733) % 20),
            N'Анна', N'Галина', N'Дарина', N'Катерина', N'Леся',
            N'Марта', N'Надія', N'Ольга', N'Софія', N'Христина',
            N'Яна', N'Аліна', N'Марія', N'Юлія', N'Олена',
            N'Наталія', N'Ірина', N'Тетяна', N'Оксана', N'Вікторія'
        ) 
    END AS FirstName,
    -- Чоловічі (n % 2 = 1) та Жіночі (n % 2 = 0) по батькові
    CASE 
        WHEN n % 15 = 0 THEN NULL 
        WHEN n % 2 = 1 THEN CHOOSE(1 + ((n * 5431) % 20),
            N'Олександрович', N'Іванович', N'Максимович', N'Андрійович', N'Дмитрович',
            N'Сергійович', N'Володимирович', N'Богданович', N'Артемович', N'Васильович',
            N'Данилович', N'Ігорович', N'Михайлович', N'Тарасович', N'Олегович',
            N'Павлович', N'Романович', N'Юрійович', N'Миколайович', N'Петрович'
        )
        ELSE CHOOSE(1 + ((n * 5431) % 20),
            N'Олександрівна', N'Іванівна', N'Максимівна', N'Андріївна', N'Дмитрівна',
            N'Сергіївна', N'Володимирівна', N'Богданівна', N'Артемівна', N'Василівна',
            N'Данилівна', N'Ігорівна', N'Михайлівна', N'Тарасівна', N'Олегівна',
            N'Павлівна', N'Романівна', N'Юріївна', N'Миколаївна', N'Петрівна'
        ) 
    END AS MiddleName,
    DATEADD(DAY, (n * 17) % 27000, CAST('1940-01-01' AS DATE)) AS BirthDate,
    CASE WHEN n % 2 = 1 THEN 'M' ELSE 'F' END AS Gender,
    CHOOSE(1 + (n % 9), 'O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', NULL) AS BloodType,
    CHOOSE(1 + ((n * 4027) % 6),
        N'Галицький район', N'Франківський район', N'Личаківський район',
        N'Сихівський район', N'Шевченківський район', N'Залізничний район'
    ) AS DistrictName,
    N'м. Львів, вул. ' + CHOOSE(1 + ((n * 3259) % 30),
        N'Городоцька', N'Стрийська', N'Зелена', N'Личаківська', N'Шевченка',
        N'Наукова', N'Кульпарківська', N'Володимира Великого', N'Червоної Калини', N'Сахарова',
        N'Степана Бандери', N'Івана Франка', N'Коперника', N'Петра Дорошенка', N'Пасічна',
        N'Гетьмана Мазепи', N'В''ячеслава Чорновола', N'Любінська', N'Івана Виговського', N'Княгині Ольги',
        N'Січових Стрільців', N'Підвальна', N'Пекарська', N'Генерала Чупринки', N'Антоновича',
        N'Богдана Хмельницького', N'Левандівська', N'Сяйво', N'Ряшівська', N'Широка'
    ) + N', буд. ' + CAST(1 + ((n * 13) % 200) AS NVARCHAR(10)) 
      + ISNULL(N', кв. ' + CAST(NULLIF(1 + ((n * 17) % 150), 150) AS NVARCHAR(10)), N'') AS AddressLine,
    '+38' + CHOOSE(1 + ((n * 2287) % 9), '067', '068', '096', '097', '050', '095', '066', '063', '073') 
          + RIGHT('0000000' + CAST(((CAST(n AS BIGINT) * 1234567) % 9000000) + 1000000 AS VARCHAR(10)), 7) AS Phone,
    DATEADD(DAY, n % 365, CAST('2015-01-01' AS DATE)) AS RegistrationDate,
    SYSDATETIME() AS UpdatedAt
FROM #Numbers
WHERE n <= 60000;
SET IDENTITY_INSERT dbo.Patients OFF;

PRINT N'4. Таблицю Patients (60 000 пацієнтів) згенеровано.';
GO

/* ---------------------------------------------------------------------
   КРОК 5. Генерація довідника Diseases (2 000 хвороб МКХ-10)
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Diseases ON;
INSERT INTO dbo.Diseases WITH (TABLOCK) (
    DiseaseID, ICD10Code, DiseaseName, DiseaseCategory, IsChronic
)
SELECT 
    n AS DiseaseID,
    CHAR(65 + ((n - 1) / 100)) + RIGHT('00' + CAST(((n - 1) % 100) AS VARCHAR(2)), 2) + '.' + CAST((n % 9) + 1 AS VARCHAR(1)) AS ICD10Code,
    CHOOSE(1 + ((n * 13) % 12),
        N'Гостра респіраторна вірусна інфекція', N'Есенціальна (первинна) гіпертензія',
        N'Гострий бронхіт', N'Хронічний гастрит та дуоденіт',
        N'Цукровий діабет ІІ типу', N'Остеохондроз хребта',
        N'Ішемічна хвороба серця', N'Бронхіальна астма',
        N'Гострий синусит (гайморит)', N'Алергічний риніт',
        N'Мігрень', N'Тубулоінтерстиціальний нефрит'
    ) + N' (клінічна форма №' + CAST(n AS NVARCHAR(10)) + N')' AS DiseaseName,
    CHOOSE(1 + ((n - 1) / 200),
        N'Хвороби органів дихання', N'Хвороби системи кровообігу',
        N'Хвороби органів травлення', N'Ендокринні та метаболічні хвороби',
        N'Хвороби кістково-м''язової системи', N'Хвороби нервової системи',
        N'Інфекційні та паразитарні хвороби', N'Хвороби сечостатевої системи',
        N'Хвороби ока та придаткового апарату', N'Хвороби шкіри та підшкірної клітковини'
    ) AS DiseaseCategory,
    CASE WHEN (n * 7) % 4 = 0 THEN 1 ELSE 0 END AS IsChronic
FROM #Numbers
WHERE n <= 2000;
SET IDENTITY_INSERT dbo.Diseases OFF;

/* ---------------------------------------------------------------------
   КРОК 6. Генерація довідника Medications (100 000 препаратів)
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Medications ON;
INSERT INTO dbo.Medications WITH (TABLOCK) (
    MedicationID, RegistrationCode, TradeName, ActiveSubstance,
    PharmacologicalGroup, ReleaseForm, Manufacturer, UnitPrice
)
SELECT 
    n AS MedicationID,
    'UA/' + RIGHT('000000' + CAST(n AS VARCHAR(10)), 6) + '/01/01' AS RegistrationCode,
    CHOOSE(1 + ((n * 11) % 16),
        N'Амоксиклав', N'Ібупрофен-Форте', N'Парацетамол-Дарниця', N'Лозартан-Тева',
        N'Омепразол-Астра', N'Метформін-Ретард', N'Азитроміцин-Здоров''я', N'Бісопролол-КРКА',
        N'Цетиризин-Гексал', N'Аторвастатин-Плюс', N'Диклофенак-Ультра', N'Пантопразол-Макс',
        N'Німесулід-Фармак', N'Еналаприл-Н', N'Амброксол-Екстра', N'Левофлоксацин-Про'
    ) + N' ' + CAST(50 + ((n % 10) * 50) AS NVARCHAR(10)) + N'мг (серія ' + CAST(n AS NVARCHAR(10)) + N')' AS TradeName,
    CHOOSE(1 + ((n * 11) % 16),
        N'Amoxicillin', N'Ibuprofen', N'Paracetamol', N'Losartan',
        N'Omeprazole', N'Metformin', N'Azithromycin', N'Bisoprolol',
        N'Cetirizine', N'Atorvastatin', N'Diclofenac', N'Pantoprazole',
        N'Nimesulide', N'Enalapril', N'Ambroxol', N'Levofloxacin'
    ) AS ActiveSubstance,
    CHOOSE(1 + ((n * 17) % 8),
        N'Антибактеріальні засоби', N'Нестероїдні протизапальні препарати',
        N'Анальгетики та антипіретики', N'Гіпотензивні препарати',
        N'Засоби для лікування кислотозалежних захворювань', N'Гіпоглікемічні засоби',
        N'Антигістамінні препарати', N'Муколітичні засоби'
    ) AS PharmacologicalGroup,
    CHOOSE(1 + ((n * 19) % 8),
        N'Таблетки', N'Капсули', N'Ампули', N'Сироп',
        N'Мазь', N'Краплі', N'Спрей', N'Порошок'
    ) AS ReleaseForm,
    CHOOSE(1 + ((n * 23) % 10),
        N'АТ Фармак (Україна)', N'ПрАТ Дарниця (Україна)', N'Корпорація Артеріум (Україна)',
        N'KRKA (Словенія)', N'Teva (Ізраїль)', N'Sanofi (Франція)',
        N'Bayer (Німеччина)', N'Sandoz (Швейцарія)', N'Pfizer (США)', N'AstraZeneca (Велика Британія)'
    ) AS Manufacturer,
    CAST(45.00 + ((n * 37) % 1450) * 1.15 AS DECIMAL(10,2)) AS UnitPrice
FROM #Numbers
WHERE n <= 100000;
SET IDENTITY_INSERT dbo.Medications OFF;

PRINT N'5. Довідники Diseases (2 000) та Medications (100 000) згенеровано.';
GO

/* ---------------------------------------------------------------------
   КРОК 7. Генерація протипоказань (60 000 записів сумарно)
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.MedicationDiseaseContraindications ON;
INSERT INTO dbo.MedicationDiseaseContraindications WITH (TABLOCK) (
    ContraindicationID, MedicationID, DiseaseID, SeverityLevel, Notes
)
SELECT 
    n AS ContraindicationID,
    90001 + ((n - 1) % 10000) AS MedicationID,
    1 + ((((n - 1) % 10000) + ((n - 1) / 10000) * 333) % 2000) AS DiseaseID,
    CHOOSE(1 + (n % 3), N'Абсолютне', N'Відносне', N'З обережністю') AS SeverityLevel,
    N'Клінічне застереження щодо взаємодії активної речовини при даній патології' AS Notes
FROM #Numbers
WHERE n <= 30000;
SET IDENTITY_INSERT dbo.MedicationDiseaseContraindications OFF;

SET IDENTITY_INSERT dbo.PatientContraindications ON;
INSERT INTO dbo.PatientContraindications WITH (TABLOCK) (
    PatientContraID, PatientID, MedicationID, ReactionType, SeverityLevel, DiscoveredDate
)
SELECT 
    n AS PatientContraID,
    1 + (n - 1) AS PatientID,
    90001 + ((n - 1) % 10000) AS MedicationID,
    CHOOSE(1 + ((n * 11) % 5),
        N'Гостра кропив''янка', N'Ангіоневротичний набряк (Квінке)',
        N'Бронхоспазм', N'Токсико-алергічний дерматит', N'Анафілактичний шок в анамнезі'
    ) AS ReactionType,
    CHOOSE(1 + (n % 3), N'Абсолютне', N'Високе', N'Помірне') AS SeverityLevel,
    DATEADD(DAY, n % 1500, CAST('2011-01-01' AS DATE)) AS DiscoveredDate
FROM #Numbers
WHERE n <= 30000;
SET IDENTITY_INSERT dbo.PatientContraindications OFF;

PRINT N'6. Таблиці протипоказань (60 000 записів) згенеровано.';
GO

/* ---------------------------------------------------------------------
   КРОК 8. Генерація Visits (550 000) та Diagnoses (550 000) за 10 років
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Visits ON;
INSERT INTO dbo.Visits WITH (TABLOCK) (
    VisitID, PatientID, DoctorID, VisitDateTime,
    VisitType, DurationMinutes, IsFreeNSZU,
    Complaints, UpdatedAt
)
SELECT 
    CAST(n AS BIGINT) AS VisitID,
    1 + ((n - 1) % 60000) AS PatientID,
    1 + ((n * 7) % 500) AS DoctorID,
    DATEADD(
        MINUTE, 
        480 + ((n * 13) % 600), 
        DATEADD(DAY, (CAST(n AS BIGINT) * 2654435761) % 3652, CAST('2016-01-01 00:00:00' AS DATETIME2(0)))
    ) AS VisitDateTime,
    CHOOSE(1 + ((n * 19) % 4), N'Первинний', N'Повторний', N'Профілактичний', N'Невідкладний') AS VisitType,
    15 + ((n * 5) % 45) AS DurationMinutes,
    CASE WHEN n % 5 = 0 THEN 1 ELSE 0 END AS IsFreeNSZU, -- 20% візитів безкоштовні за програмою НСЗУ
    CASE 
        WHEN n % 10 = 0 THEN NULL 
        ELSE CHOOSE(1 + ((n * 23) % 8),
            N'Скарги на підвищення температури тіла, загальну слабкість та кашель',
            N'Скарги на періодичний головний біль та підвищення артеріального тиску',
            N'Біль у ділянці хребта та суглобів при фізичному навантаженні',
            N'Скарги на біль в епігастральній ділянці та печію після прийому їжі',
            N'Плановий контрольний огляд для корекції схеми лікування',
            N'Скарги на задишку, прискорене серцебиття та швидку втомлюваність',
            N'Закладеність носа, біль у горлі та осиплість голосу',
            N'Профілактичне обстеження та виписка електронного рецепта'
        )
    END AS Complaints,
    SYSDATETIME() AS UpdatedAt
FROM #Numbers
WHERE n <= 550000;
SET IDENTITY_INSERT dbo.Visits OFF;

SET IDENTITY_INSERT dbo.Diagnoses ON;
INSERT INTO dbo.Diagnoses WITH (TABLOCK) (
    DiagnosisID, VisitID, DiseaseID, DiagnosisDate,
    IsPrimary, Severity, TreatmentOutcome,
    RecoveryDate, SickLeaveDays, UpdatedAt
)
SELECT 
    CAST(n AS BIGINT) AS DiagnosisID,
    CAST(n AS BIGINT) AS VisitID,
    1 + ((n * 11) % 2000) AS DiseaseID,
    DATEADD(DAY, (CAST(n AS BIGINT) * 2654435761) % 3652, CAST('2016-01-01' AS DATE)) AS DiagnosisDate,
    CASE WHEN n % 10 = 0 THEN 0 ELSE 1 END AS IsPrimary,
    CHOOSE(1 + ((n * 29) % 4), N'Легка', N'Середня', N'Тяжка', N'Критична') AS Severity,
    CHOOSE(1 + ((n * 31) % 7),
        N'Одужання', N'Покращення', N'Одужання',
        N'Без змін', N'Ускладнення', N'Направлено в стаціонар', N'В процесі'
    ) AS TreatmentOutcome,
    -- RecoveryDate = NULL лише тоді, коли лікування ще триває ("В процесі")
    CASE 
        WHEN ((n * 31) % 7) = 6 THEN NULL 
        ELSE DATEADD(DAY, 5 + (n % 21), DATEADD(DAY, (CAST(n AS BIGINT) * 2654435761) % 3652, CAST('2016-01-01' AS DATE))) 
    END AS RecoveryDate,
    CASE WHEN n % 3 = 0 THEN 0 ELSE 3 + (n % 15) END AS SickLeaveDays,
    SYSDATETIME() AS UpdatedAt
FROM #Numbers
WHERE n <= 550000;
SET IDENTITY_INSERT dbo.Diagnoses OFF;

PRINT N'7. Таблиці Visits (550 000) та Diagnoses (550 000) згенеровано.';
GO

/* ---------------------------------------------------------------------
   КРОК 9. Генерація Prescriptions (600 000 рецептів)
   --------------------------------------------------------------------- */
SET IDENTITY_INSERT dbo.Prescriptions ON;
INSERT INTO dbo.Prescriptions WITH (TABLOCK) (
    PrescriptionID, DiagnosisID, MedicationID, DailyDosage,
    DurationDays, QuantityPackages, IsSubsidized, CreatedAt
)
SELECT 
    CAST(n AS BIGINT) AS PrescriptionID,
    1 + ((n - 1) % 550000) AS DiagnosisID,
    1 + ((n * 13) % 90000) AS MedicationID,
    CHOOSE(1 + ((n * 37) % 6),
        N'По 1 табл. 2 рази на добу після їжі',
        N'По 1 капс. 3 рази на добу за 30 хв до їжі',
        N'По 5 мл сиропу 3 рази на добу',
        N'По 1 табл. 1 раз на добу вранці',
        N'По 2 краплі 4 рази на добу',
        N'Внутрішньом''язово по 1 ампулі 1 раз на добу'
    ) AS DailyDosage,
    5 + (n % 25) AS DurationDays,
    1 + (n % 4) AS QuantityPackages,
    CASE WHEN n % 4 = 0 THEN 1 ELSE 0 END AS IsSubsidized,
    SYSDATETIME() AS CreatedAt
FROM #Numbers
WHERE n <= 600000;
SET IDENTITY_INSERT dbo.Prescriptions OFF;

PRINT N'8. Таблицю Prescriptions (600 000 рецептів) згенеровано.';
GO

/* ---------------------------------------------------------------------
   КРОК 10. Завершення: увімкнення тригерів та оновлення статистики
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS #Numbers;

ENABLE TRIGGER ALL ON dbo.Prescriptions;
ENABLE TRIGGER ALL ON dbo.Visits;
ENABLE TRIGGER ALL ON dbo.Patients;
ENABLE TRIGGER ALL ON dbo.Diagnoses;

EXEC sp_updatestats;
GO

DECLARE @StartTime DATETIME2 = (SELECT TOP 1 StartTime FROM #ScriptTimer);
DECLARE @ElapsedSeconds INT = DATEDIFF(SECOND, @StartTime, SYSDATETIME());
DROP TABLE IF EXISTS #ScriptTimer;

PRINT N'=== ГЕНЕРАЦІЮ УСПІШНО ЗАВЕРШЕНО ЗА ' + CAST(@ElapsedSeconds AS NVARCHAR(10)) + N' СЕКУНД! ===';
GO