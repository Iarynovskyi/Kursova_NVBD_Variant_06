# -*- coding: utf-8 -*-
"""
GENERATE_BRANCH_ARCHIVE.py — генерація CSV-архіву «Філії №2» (Етап 3, джерело для SSIS)

Філія №2 до 2026 року вела облік прийомів у застарілій системі. Її вивантаження —
10 річних CSV-файлів (2016–2025) з типовими проблемами якості даних, які ETL має
очистити (Data Cleansing), стандартизувати (Data Conversion), відфільтрувати
(Conditional Split -> etl.ErrorRecords) та об'єднати з основним джерелом (Union All).

Записи посилаються на РЕАЛЬНІ медичні картки пацієнтів і ліцензії лікарів з PolyclinicOLTP:
скрипт відтворює ту саму детерміновану генерацію (MD5-хеш), що й GENERATE_DATA.sql,
тому дати візитів не передують народженню/реєстрації пацієнта і періоду роботи лікаря.

Запуск:  python GENERATE_BRANCH_ARCHIVE.py   (Python 3.8+, лише стандартна бібліотека)
Результат: DataGeneration/BranchArchive/Branch2_Visits_<рік>.csv  (UTF-8 BOM, роздільник «;»)
"""
import csv
import hashlib
import os
import random
from datetime import date, datetime, timedelta

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'BranchArchive')
SEED = 20260001

# ------------------------------------------------------------------ відтворення OLTP-генератора
def rnd(salt, n):
    """Аналог dbo.gen_Rnd: 8 цілих 0..2^31-1 з MD5(salt|n) і MD5(salt#n)."""
    h1 = hashlib.md5(f'{salt}|{n}'.encode('ascii')).digest()
    h2 = hashlib.md5(f'{salt}#{n}'.encode('ascii')).digest()
    return [int.from_bytes(h[i:i + 4], 'big') & 0x7FFFFFFF for h in (h1, h2) for i in (0, 4, 8, 12)]


def dmax(a, b):
    return a if a > b else b


SPEC_QUOTA = [(1, 80), (2, 100), (3, 30), (4, 25), (5, 25), (6, 25), (7, 25), (8, 25), (9, 20), (10, 20),
              (11, 15), (12, 15), (13, 15), (14, 25), (15, 10), (16, 10), (17, 10), (18, 10), (19, 8), (20, 7)]
SPEC_MIN = {1: 20, 2: 20, 3: 30, 4: 30, 5: 25, 6: 25, 7: 20, 8: 20, 9: 30, 10: 30,
            11: 30, 12: 20, 13: 25, 14: 30, 15: 30, 16: 30, 17: 25, 18: 30, 19: 35, 20: 40}
SPEC_RATE = {1: 450, 2: 420, 3: 700, 4: 680, 5: 900, 6: 850, 7: 600, 8: 580, 9: 650, 10: 660,
             11: 640, 12: 550, 13: 720, 14: 750, 15: 670, 16: 690, 17: 620, 18: 710, 19: 800, 20: 950}


def build_doctors():
    docs, n = [], 0
    for spec, cnt in SPEC_QUOTA:
        for k in range(1, cnt + 1):
            n += 1
            r = rnd('DOC', n)
            if k == 1:
                hire = date(1990, 1, 1) + timedelta(days=r[3] % 7300)
            elif r[4] % 100 < 15:
                hire = date(2016, 1, 1) + timedelta(days=r[4] % 3288)
            else:
                hire = date(1985, 1, 1) + timedelta(days=r[4] % 11322)
            dism_start = dmax(hire + timedelta(days=365), date(2016, 6, 1))
            dismissal = None
            if k > 1 and r[5] % 100 < 5 and dism_start <= date(2025, 9, 30):
                dismissal = dism_start + timedelta(days=r[6] % ((date(2025, 9, 30) - dism_start).days + 1))
            docs.append({'id': n, 'spec': spec, 'hire': hire, 'dismissal': dismissal,
                         'license': 'LIC-UA-' + str(100000 + n * 37).zfill(6)[-6:]})
    return docs


def build_patients():
    pats = []
    for n in range(1, 60001):
        r = rnd('PAT', n)
        gender = 'M' if r[0] % 1000 < 470 else 'F'
        b = r[1] % 100
        age = 1 + r[2] % 17 if b < 14 else 18 + r[2] % 22 if b < 40 else 40 + r[2] % 20 if b < 70 else 60 + r[2] % 33
        birth = date(2025 - age, 12, 31) - timedelta(days=r[3] % 365)
        old = r[4] % 100 < 72 and birth <= date(2015, 12, 31)
        if old:
            start, end = dmax(birth, date(2008, 1, 1)), date(2015, 12, 31)
        else:
            start, end = dmax(birth, date(2016, 1, 1)), date(2025, 10, 31)
        reg = start if start > end else start + timedelta(days=r[5] % ((end - start).days + 1))
        pats.append({'id': n, 'card': 'MC-' + str(n).zfill(7), 'gender': gender, 'birth': birth, 'reg': reg})
    return pats


# ------------------------------------------------------------------ довідник хвороб (як у GENERATE_DATA.sql)
# (ICD10, категорія, хронічна, профільна спеціальність, вага, сезон, стать, мін.вік, макс.вік, дні від, дні до, % лікарняних, рівень тяжкості)
DISEASES = [
    ('J06.9', 'RES', 0, 2, 300, 1, None, 0, 120, 5, 10, 70, 1),
    ('J00', 'RES', 0, 2, 110, 1, None, 0, 120, 4, 8, 40, 1),
    ('J02.9', 'RES', 0, 2, 90, 1, None, 0, 120, 5, 9, 50, 1),
    ('J03.9', 'RES', 0, 8, 60, 1, None, 3, 70, 7, 12, 80, 2),
    ('J01.0', 'RES', 0, 8, 50, 1, None, 7, 120, 10, 18, 70, 2),
    ('J20.9', 'RES', 0, 2, 110, 1, None, 0, 120, 10, 18, 75, 2),
    ('J18.9', 'RES', 0, 11, 25, 1, None, 0, 120, 14, 28, 95, 3),
    ('J11.1', 'RES', 0, 2, 70, 1, None, 0, 120, 7, 12, 90, 2),
    ('J45.0', 'RES', 1, 11, 60, 2, None, 5, 90, 14, 30, 30, 2),
    ('J44.9', 'RES', 1, 11, 45, 1, None, 40, 120, 14, 30, 40, 2),
    ('J30.1', 'RES', 0, 16, 70, 2, None, 5, 90, 10, 21, 5, 1),
    ('J31.0', 'RES', 1, 8, 20, 0, None, 10, 120, 10, 20, 5, 1),
    ('J32.0', 'RES', 1, 8, 20, 1, None, 18, 120, 14, 21, 30, 2),
    ('A09', 'INF', 0, 2, 60, 3, None, 0, 120, 3, 7, 60, 1),
    ('B01.9', 'INF', 0, 17, 15, 1, None, 0, 60, 7, 14, 90, 1),
    ('B27.9', 'INF', 0, 17, 8, 0, None, 10, 35, 14, 28, 95, 2),
    ('B35.1', 'INF', 0, 12, 25, 3, None, 18, 120, 30, 90, 0, 1),
    ('B02.9', 'INF', 0, 12, 12, 0, None, 40, 120, 10, 21, 70, 2),
    ('A46', 'INF', 0, 5, 6, 3, None, 30, 120, 10, 20, 90, 2),
    ('U07.1', 'COV', 0, 2, 40, 1, None, 0, 120, 7, 21, 95, 2),
    ('D25.9', 'NEO', 1, 14, 25, 0, 'F', 30, 60, 30, 60, 5, 1),
    ('D22.9', 'NEO', 0, 12, 25, 3, None, 18, 120, 1, 3, 0, 1),
    ('C50.9', 'NEO', 1, 20, 10, 0, 'F', 35, 120, 30, 90, 60, 3),
    ('C61', 'NEO', 1, 20, 7, 0, 'M', 50, 120, 30, 90, 40, 3),
    ('C18.9', 'NEO', 1, 20, 6, 0, None, 45, 120, 30, 90, 60, 3),
    ('D17.9', 'NEO', 0, 5, 15, 0, None, 25, 120, 7, 14, 20, 1),
    ('D50.9', 'BLD', 0, 19, 35, 0, None, 14, 120, 30, 60, 10, 1),
    ('D51.9', 'BLD', 1, 19, 10, 0, None, 40, 120, 30, 60, 10, 1),
    ('E11.9', 'END', 1, 10, 120, 0, None, 35, 120, 30, 90, 15, 2),
    ('E10.9', 'END', 1, 10, 15, 0, None, 5, 120, 30, 90, 20, 2),
    ('E03.9', 'END', 1, 10, 50, 0, None, 18, 120, 30, 60, 10, 1),
    ('E05.0', 'END', 1, 10, 15, 0, None, 18, 120, 30, 90, 40, 2),
    ('E66.9', 'END', 1, 10, 40, 0, None, 18, 120, 30, 90, 0, 1),
    ('E78.0', 'END', 1, 3, 80, 0, None, 30, 120, 30, 90, 0, 1),
    ('E55.9', 'END', 0, 2, 30, 1, None, 0, 120, 30, 90, 0, 1),
    ('G43.0', 'NRV', 1, 4, 50, 0, None, 12, 70, 3, 7, 40, 2),
    ('G40.9', 'NRV', 1, 4, 12, 0, None, 3, 120, 30, 90, 30, 2),
    ('G44.2', 'NRV', 0, 4, 55, 0, None, 15, 120, 3, 10, 20, 1),
    ('G47.0', 'NRV', 0, 4, 25, 0, None, 18, 120, 14, 30, 0, 1),
    ('G51.0', 'NRV', 0, 4, 6, 1, None, 10, 120, 21, 45, 90, 2),
    ('G62.9', 'NRV', 1, 4, 25, 0, None, 40, 120, 30, 60, 20, 2),
    ('G45.9', 'NRV', 0, 4, 10, 0, None, 45, 120, 7, 21, 80, 3),
    ('H10.9', 'EYE', 0, 7, 70, 2, None, 0, 120, 3, 10, 30, 1),
    ('H40.1', 'EYE', 1, 7, 30, 0, None, 40, 120, 30, 90, 0, 2),
    ('H25.9', 'EYE', 1, 7, 35, 0, None, 55, 120, 30, 60, 10, 1),
    ('H52.1', 'EYE', 1, 7, 45, 0, None, 6, 60, 1, 3, 0, 1),
    ('H04.1', 'EYE', 1, 7, 25, 0, None, 30, 120, 14, 30, 0, 1),
    ('H00.0', 'EYE', 0, 7, 20, 0, None, 5, 120, 5, 10, 10, 1),
    ('H66.9', 'EAR', 0, 8, 45, 1, None, 0, 120, 7, 14, 70, 2),
    ('H61.2', 'EAR', 0, 8, 30, 0, None, 3, 120, 1, 3, 0, 1),
    ('H90.3', 'EAR', 1, 8, 15, 0, None, 45, 120, 30, 60, 0, 1),
    ('H81.1', 'EAR', 0, 4, 20, 0, None, 30, 120, 7, 14, 50, 1),
    ('I10', 'CIR', 1, 3, 250, 0, None, 30, 120, 30, 90, 15, 2),
    ('I11.9', 'CIR', 1, 3, 80, 0, None, 40, 120, 30, 90, 20, 2),
    ('I20.8', 'CIR', 1, 3, 60, 0, None, 45, 120, 30, 60, 40, 3),
    ('I25.1', 'CIR', 1, 3, 70, 0, None, 45, 120, 30, 90, 30, 2),
    ('I48.9', 'CIR', 1, 3, 35, 0, None, 50, 120, 30, 90, 40, 3),
    ('I50.0', 'CIR', 1, 3, 40, 0, None, 55, 120, 30, 90, 50, 3),
    ('I49.9', 'CIR', 1, 3, 25, 0, None, 30, 120, 14, 60, 30, 2),
    ('I83.9', 'CIR', 1, 5, 45, 3, None, 25, 120, 30, 60, 10, 1),
    ('I21.9', 'CIR', 0, 3, 6, 0, None, 45, 120, 30, 60, 100, 3),
    ('I63.9', 'CIR', 0, 4, 6, 0, None, 50, 120, 30, 90, 100, 3),
    ('I95.9', 'CIR', 0, 3, 10, 3, None, 15, 120, 3, 7, 10, 1),
    ('K29.5', 'DIG', 1, 9, 90, 0, None, 18, 120, 14, 30, 20, 1),
    ('K25.9', 'DIG', 1, 9, 30, 0, None, 20, 120, 21, 45, 70, 2),
    ('K26.9', 'DIG', 1, 9, 25, 0, None, 20, 120, 21, 45, 70, 2),
    ('K21.0', 'DIG', 1, 9, 70, 0, None, 18, 120, 14, 30, 10, 1),
    ('K58.9', 'DIG', 1, 9, 40, 0, None, 18, 60, 14, 30, 10, 1),
    ('K80.2', 'DIG', 1, 5, 30, 0, None, 30, 120, 14, 30, 30, 2),
    ('K81.1', 'DIG', 1, 9, 35, 0, None, 25, 120, 14, 30, 40, 2),
    ('K86.1', 'DIG', 1, 9, 30, 0, None, 25, 120, 14, 30, 40, 2),
    ('K76.0', 'DIG', 1, 9, 30, 0, None, 30, 120, 30, 60, 0, 1),
    ('K74.6', 'DIG', 1, 9, 8, 0, None, 40, 120, 30, 60, 60, 3),
    ('K40.9', 'DIG', 0, 5, 15, 0, 'M', 18, 120, 14, 30, 80, 2),
    ('K35.8', 'DIG', 0, 5, 8, 0, None, 5, 60, 14, 21, 100, 3),
    ('K59.0', 'DIG', 0, 2, 25, 0, None, 3, 120, 3, 10, 0, 1),
    ('L20.9', 'SKN', 1, 12, 35, 1, None, 1, 60, 14, 30, 10, 1),
    ('L23.9', 'SKN', 0, 12, 40, 3, None, 3, 120, 7, 14, 15, 1),
    ('L40.0', 'SKN', 1, 12, 25, 0, None, 15, 120, 30, 60, 20, 2),
    ('L70.0', 'SKN', 0, 12, 35, 0, None, 12, 30, 30, 60, 0, 1),
    ('L50.0', 'SKN', 0, 16, 35, 2, None, 3, 120, 5, 10, 20, 1),
    ('L02.4', 'SKN', 0, 5, 25, 3, None, 10, 120, 7, 14, 60, 1),
    ('L60.0', 'SKN', 0, 5, 20, 0, None, 10, 120, 7, 14, 50, 1),
    ('M54.5', 'MSK', 0, 4, 120, 0, None, 20, 120, 7, 14, 75, 1),
    ('M42.1', 'MSK', 1, 4, 70, 0, None, 30, 120, 14, 30, 50, 2),
    ('M17.9', 'MSK', 1, 6, 70, 4, None, 45, 120, 14, 30, 30, 2),
    ('M16.9', 'MSK', 1, 6, 30, 0, None, 50, 120, 14, 30, 30, 2),
    ('M10.9', 'MSK', 1, 15, 25, 0, None, 35, 120, 14, 21, 50, 2),
    ('M05.9', 'MSK', 1, 15, 20, 0, None, 25, 120, 30, 60, 50, 2),
    ('M81.0', 'MSK', 1, 15, 30, 0, 'F', 50, 120, 30, 90, 0, 1),
    ('M75.1', 'MSK', 0, 6, 30, 0, None, 35, 120, 14, 30, 60, 1),
    ('M79.1', 'MSK', 0, 2, 30, 0, None, 15, 120, 5, 10, 30, 1),
    ('M54.2', 'MSK', 0, 4, 50, 0, None, 18, 120, 7, 14, 50, 1),
    ('N30.0', 'GEN', 0, 13, 45, 0, 'F', 15, 120, 5, 10, 50, 1),
    ('N39.0', 'GEN', 0, 2, 50, 0, None, 3, 120, 7, 14, 50, 1),
    ('N40', 'GEN', 1, 13, 50, 0, 'M', 45, 120, 30, 90, 5, 1),
    ('N20.0', 'GEN', 1, 13, 30, 3, None, 25, 120, 14, 30, 70, 2),
    ('N18.3', 'GEN', 1, 18, 30, 0, None, 40, 120, 30, 90, 20, 2),
    ('N11.9', 'GEN', 1, 18, 25, 0, None, 15, 120, 14, 30, 60, 2),
    ('N76.0', 'GEN', 0, 14, 45, 0, 'F', 15, 120, 7, 14, 20, 1),
    ('N95.1', 'GEN', 1, 14, 35, 0, 'F', 45, 60, 30, 90, 0, 1),
    ('N92.0', 'GEN', 0, 14, 30, 0, 'F', 12, 50, 14, 30, 10, 1),
    ('N60.1', 'GEN', 1, 14, 30, 0, 'F', 20, 55, 30, 60, 0, 1),
    ('N41.1', 'GEN', 1, 13, 30, 0, 'M', 25, 120, 21, 30, 20, 1),
    ('S93.4', 'INJ', 0, 6, 60, 4, None, 5, 120, 14, 21, 85, 1),
    ('S52.5', 'INJ', 0, 6, 30, 4, None, 5, 120, 30, 45, 95, 2),
    ('S82.6', 'INJ', 0, 6, 18, 4, None, 10, 120, 42, 60, 100, 2),
    ('S01.8', 'INJ', 0, 5, 20, 3, None, 0, 120, 7, 14, 50, 1),
    ('T14.0', 'INJ', 0, 6, 50, 4, None, 0, 120, 5, 10, 40, 1),
    ('S06.0', 'INJ', 0, 4, 15, 4, None, 3, 120, 14, 21, 100, 2),
    ('T63.4', 'INJ', 0, 2, 15, 3, None, 0, 120, 2, 5, 0, 1),
    ('T78.4', 'INJ', 0, 16, 25, 2, None, 0, 120, 5, 10, 10, 1),
    ('T30.0', 'INJ', 0, 5, 10, 3, None, 0, 120, 7, 21, 60, 1),
    ('Z00.0', 'ZZZ', 0, 2, 100, 0, None, 0, 120, 0, 0, 0, 1),
    ('Z01.0', 'ZZZ', 0, 7, 25, 0, None, 0, 120, 0, 0, 0, 1),
    ('Z13.6', 'ZZZ', 0, 3, 20, 0, None, 40, 120, 0, 0, 0, 1),
    ('Z25.1', 'ZZZ', 0, 2, 20, 5, None, 0, 120, 0, 0, 0, 1),
    ('Z01.4', 'ZZZ', 0, 14, 30, 0, 'F', 18, 120, 0, 0, 0, 1),
    ('Z02.7', 'ZZZ', 0, 2, 30, 0, None, 3, 120, 0, 0, 0, 1),
]
SEASON = {
    0: [1.0] * 12,
    1: [2.2, 2.4, 1.8, 1.1, 0.6, 0.4, 0.3, 0.35, 0.8, 1.3, 1.7, 2.0],
    2: [0.3, 0.3, 0.8, 2.0, 2.6, 2.0, 1.4, 1.2, 1.0, 0.5, 0.3, 0.3],
    3: [0.6, 0.6, 0.7, 0.9, 1.2, 1.6, 1.9, 1.8, 1.2, 0.9, 0.7, 0.6],
    4: [1.8, 1.6, 1.1, 0.8, 0.8, 0.9, 0.9, 0.9, 0.8, 0.9, 1.1, 1.6],
    5: [0.4, 0.3, 0.2, 0.1, 0.1, 0.1, 0.1, 0.2, 1.5, 3.0, 2.5, 1.0],
}
MONTH_W = [1.22, 1.25, 1.12, 0.98, 0.92, 0.82, 0.72, 0.76, 1.00, 1.10, 1.18, 1.08]
EUR_RATE = {2016: 28.29, 2017: 30.00, 2018: 32.14, 2019: 28.95, 2020: 30.79, 2021: 32.31,
            2022: 33.98, 2023: 39.56, 2024: 43.44, 2025: 47.00}
COMPLAINTS = {
    'RES': ['Підвищення температури, нежить, біль у горлі', 'Кашель з мокротинням, задишка'],
    'CIR': ['Підвищення артеріального тиску, головний біль', 'Біль за грудиною при навантаженні'],
    'MSK': ['Біль у попереку, обмеження рухливості', 'Біль та скутість у суглобах'],
    'DIG': ['Біль в епігастрії, печія після їжі', 'Здуття живота, порушення випорожнень'],
    'INJ': ['Біль та набряк після падіння', 'Травма під час занять спортом'],
    'ZZZ': ['Плановий профілактичний огляд', 'Отримання медичної довідки'],
}
OUTCOMES = ['Одужання', 'Покращення', 'Без змін', 'Хронізація', 'Ускладнення', 'Направлено в стаціонар', 'В процесі']


def pick_severity(rng, lvl):
    p = {1: (650, 950, 995), 2: (350, 800, 970), 3: (100, 500, 880)}[lvl]
    x = rng.randrange(1000)
    return 'Легка' if x < p[0] else 'Середня' if x < p[1] else 'Тяжка' if x < p[2] else 'Критична'


def pick_outcome(rng, chronic, sev):
    x = rng.randrange(100)
    if chronic:
        if sev == 'Критична':
            return 'Направлено в стаціонар' if x < 50 else 'Ускладнення' if x < 80 else 'Покращення'
        return 'Покращення' if x < 55 else 'Без змін' if x < 93 else 'Ускладнення'
    if sev in ('Тяжка', 'Критична'):
        return 'Направлено в стаціонар' if x < 20 else 'Ускладнення' if x < 30 else 'Покращення' if x < 60 else 'Одужання'
    return 'Одужання' if x < 75 else 'Покращення' if x < 93 else 'Без змін'


def age_at(birth, d):
    return d.year - birth.year - ((d.month, d.day) < (birth.month, birth.day))


# ------------------------------------------------------------------ «зіпсовані» представлення значень
def fmt_dt(rng, dt, stats):
    x = rng.random()
    if x < 0.003:
        stats['bad_date'] += 1
        return rng.choice(['31.02.' + str(dt.year) + ' 10:00', 'н/д', '00.00.0000'])
    if x < 0.60:
        return dt.strftime('%d.%m.%Y %H:%M')
    if x < 0.90:
        return dt.strftime('%Y-%m-%d %H:%M:%S')
    stats['alt_date'] += 1
    return dt.strftime('%d/%m/%Y %H:%M')


def fmt_date(rng, d):
    x = rng.random()
    return d.strftime('%d.%m.%Y') if x < 0.6 else d.strftime('%Y-%m-%d') if x < 0.9 else d.strftime('%d/%m/%Y')


def variant_case(rng, s, p_lower=0.15, p_upper=0.10):
    x = rng.random()
    return s.lower() if x < p_lower else s.upper() if x < p_lower + p_upper else s


def main():
    rng = random.Random(SEED)
    doctors, patients = build_doctors(), build_patients()
    by_spec = {}
    for d in doctors:
        by_spec.setdefault(d['spec'], []).append(d)
    by_spec_primary = by_spec[1] + by_spec[2]
    os.makedirs(OUT_DIR, exist_ok=True)

    header = ['RecordNo', 'VisitDateTime', 'PatientCard', 'DoctorLicense', 'ICD10', 'VisitType', 'Severity', 'DurationMin',
              'CostAmount', 'Currency', 'IsFreeNSZU', 'Outcome', 'RecoveryDate', 'SickLeaveDays', 'Complaints']
    total = {'rows': 0, 'dups': 0, 'bad_date': 0, 'alt_date': 0, 'bad_card': 0, 'bad_doc': 0, 'bad_icd': 0,
             'bad_dur': 0, 'empty_dur': 0, 'eur': 0, 'files': 0}

    for year in range(2016, 2026):
        n_rows = int(3200 * (1 + 0.06 * (year - 2016)) * (0.85 if year == 2020 else 1.0))
        days = [date(year, 1, 1) + timedelta(days=i) for i in range((date(year, 12, 31) - date(year, 1, 1)).days + 1)]
        days = [d for d in days if d.weekday() != 6]
        day_w = [MONTH_W[d.month - 1] * (0.3 if d.weekday() == 5 else 1.0) for d in days]
        rows, seq = [], 0
        while len(rows) < n_rows:
            d = rng.choices(days, weights=day_w)[0]
            dis_w = [x[4] * SEASON[x[5]][d.month - 1] * (0 if x[0] == 'U07.1' and (d.year, d.month) < (2020, 3) else 1) for x in DISEASES]
            icd, cat, chronic, spec, _, _, g_only, min_age, max_age, rmin, rmax, sick_pct, sev_lvl = rng.choices(DISEASES, weights=dis_w)[0]
            # пацієнт, що вже зареєстрований і відповідає статі/віку
            pat = None
            for _ in range(60):
                p = patients[rng.randrange(len(patients))]
                a = age_at(p['birth'], d)
                if p['reg'] <= d and (g_only is None or g_only == p['gender']) and min_age <= a <= max_age:
                    pat = p
                    break
            if pat is None:
                continue
            pool = by_spec_primary if spec in (1, 2) else by_spec[spec]
            pool = [x for x in pool if x['hire'] <= d and (x['dismissal'] is None or x['dismissal'] >= d)]
            if not pool:
                continue
            doc = pool[rng.randrange(len(pool))]
            seq += 1
            vt = 'Профілактичний' if cat == 'ZZZ' else (
                rng.choices(['Повторний', 'Первинний', 'Невідкладний'], [70, 20, 10])[0] if chronic else
                rng.choices(['Первинний', 'Невідкладний', 'Повторний'], [85, 10, 5])[0])
            sev = 'Легка' if cat == 'ZZZ' else pick_severity(rng, sev_lvl)
            dt = datetime(d.year, d.month, d.day, 8, 0) + timedelta(minutes=5 * rng.randrange(120 if d.weekday() < 5 else 60))
            base = SPEC_MIN[doc['spec']] * {'Профілактичний': 0.8, 'Первинний': 1.15, 'Повторний': 0.85, 'Невідкладний': 1.35}[vt]
            dur = max(5, min(180, round(base * rng.uniform(0.7, 1.3))))
            free = (doc['spec'] in (1, 2) and d >= date(2018, 7, 1) and rng.random() < 0.95) or \
                   (doc['spec'] not in (1, 2) and d >= date(2020, 4, 1) and rng.random() < 0.55)
            cost_uah = 0.0 if free else round(dur / 60 * SPEC_RATE[doc['spec']], 2)
            if cat == 'ZZZ':
                outcome, planned = 'Без змін', 0
            else:
                planned = round(rng.randint(rmin, rmax) * {'Легка': 0.8, 'Середня': 1.0, 'Тяжка': 1.4, 'Критична': 1.8}[sev])
                outcome = 'В процесі' if d + timedelta(days=planned) > date(2025, 12, 31) else pick_outcome(rng, chronic, sev)
            recovery = None if outcome == 'В процесі' else d + timedelta(days=planned + (10 if outcome == 'Направлено в стаціонар' else 0))
            a = age_at(pat['birth'], d)
            sick = 0 if cat == 'ZZZ' or a < 18 or a > 65 or rng.randrange(100) >= sick_pct else \
                min(max(planned, 1), {'Легка': rng.randint(3, 7), 'Середня': rng.randint(5, 12),
                                      'Тяжка': rng.randint(10, 25), 'Критична': rng.randint(14, 45)}[sev])

            # ---------- навмисні дефекти якості даних ----------
            card = pat['card']
            x = rng.random()
            if x < 0.003:
                card = 'MC-0' + str(rng.randint(90000, 99999)).zfill(6); total['bad_card'] += 1       # неіснуюча картка
            elif x < 0.053:
                card = card.lower()
            elif x < 0.103:
                card = '  ' + card + ' '
            elif x < 0.153:
                card = card.replace('-', '')
            lic = doc['license']
            x = rng.random()
            if x < 0.003:
                lic = 'LIC-UA-9' + str(rng.randint(10000, 99999)); total['bad_doc'] += 1               # неіснуюча ліцензія
            elif x < 0.063:
                lic = lic.lower()
            elif x < 0.123:
                lic = ' ' + lic + '  '
            code = icd
            x = rng.random()
            if x < 0.002:
                code = rng.choice(['X99.9', 'Z99.99', 'J06.99']); total['bad_icd'] += 1               # невідомий код МКХ
            elif x < 0.122:
                code = ' ' + code.lower() + ' '
            elif x < 0.202:
                code = code.replace('.', ',')
            dur_txt = str(dur)
            x = rng.random()
            if x < 0.004:
                dur_txt = rng.choice(['0', '-15', '999', '1440']); total['bad_dur'] += 1               # тривалість поза 5..180
            elif x < 0.024:
                dur_txt = ''; total['empty_dur'] += 1                                                   # NULL -> норматив спеціальності
            elif x < 0.054:
                dur_txt = dur_txt + ' хв'
            if rng.random() < 0.15 and cost_uah > 0:
                amount = round(cost_uah / EUR_RATE[year], 2); cur = rng.choice(['EUR', 'EUR', '€']); total['eur'] += 1
            else:
                amount = cost_uah; cur = rng.choice(['UAH', 'UAH', 'грн'])
            amount_txt = f'{amount:.2f}' if rng.random() < 0.6 else f'{amount:.2f}'.replace('.', ',')
            free_txt = rng.choices([('1', '0'), ('так', 'ні'), ('true', 'false')], [70, 20, 10])[0][0 if free else 1]
            vt_txt = '' if rng.random() < 0.05 else variant_case(rng, vt)
            sev_txt = '' if rng.random() < 0.05 else variant_case(rng, sev, 0.15, 0.0)
            out_txt = variant_case(rng, outcome)
            rec_txt = '' if recovery is None else fmt_date(rng, recovery)
            sick_txt = '' if sick == 0 and rng.random() < 0.6 else str(sick)
            complaint = rng.choice(COMPLAINTS.get(cat, ['Скарги згідно з медичною карткою']))
            rec_no = f'B2-{year}-{seq:06d}'
            row = [rec_no, fmt_dt(rng, dt, total), card, lic, code, vt_txt, sev_txt, dur_txt, amount_txt, cur,
                   free_txt, out_txt, rec_txt, sick_txt, complaint]
            rows.append((dt, row))
            if rng.random() < 0.015:                                                                   # повний дублікат рядка
                rows.append((dt + timedelta(seconds=1), list(row))); total['dups'] += 1

        rows.sort(key=lambda t: t[0])
        path = os.path.join(OUT_DIR, f'Branch2_Visits_{year}.csv')
        with open(path, 'w', encoding='utf-8-sig', newline='') as f:
            w = csv.writer(f, delimiter=';', quotechar='"', quoting=csv.QUOTE_MINIMAL, lineterminator='\r\n')
            w.writerow(header)
            for _, r in rows:
                w.writerow(r)
        total['rows'] += len(rows)
        total['files'] += 1
        print(f'{os.path.basename(path)}: {len(rows)} рядків')
    print('Підсумок:', total)
    return total


if __name__ == '__main__':
    main()
