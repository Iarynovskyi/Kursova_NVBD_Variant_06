/* =====================================================================
   Файл: CREATE_DATABASE.sql
   Опис: Створення транзакційної бази даних (OLTP) для Варіанту №6 "Поліклініка"
   ===================================================================== */

USE master;
GO

-- Якщо база даних вже існує, переводимо її в однокористувацький режим і видаляємо
IF DB_ID(N'PolyclinicOLTP') IS NOT NULL
BEGIN
    ALTER DATABASE PolyclinicOLTP SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PolyclinicOLTP;
END
GO

-- Створення бази даних (використовуються стандартні шляхи сервера для сумісності з Docker та Windows)
CREATE DATABASE PolyclinicOLTP;
GO

-- Налаштування параметрів БД для роботи з великими обсягами даних (500 000+ записів)
ALTER DATABASE PolyclinicOLTP SET RECOVERY SIMPLE; -- Пришвидшує генерацію даних та мінімізує ріст лог-файлу
ALTER DATABASE PolyclinicOLTP SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE PolyclinicOLTP SET AUTO_UPDATE_STATISTICS ON;
GO

USE PolyclinicOLTP;
GO

PRINT N'Базу даних PolyclinicOLTP успішно створено та налаштовано.';
GO