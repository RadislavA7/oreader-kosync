# OReader ⇄ KOReader Sync

Синхронизация позиции чтения для **старых Android-читалок**, на которые
**нельзя установить KOReader**.

Android-сборка KOReader требует **Android 4.3 (API 18)** и выше, поэтому на
устройствах с Android 2.x её просто нет. Этот проект всё равно даёт им
синхронизацию по протоколу KOReader Sync (kosync): позиция берётся из
**AlReader / OReader**, переводится в **XPointer формата KOReader** и
обменивается с любым kosync-сервером.

Основная цель и устройство, на котором всё разработано и проверено:

- **Onyx Boox i63ML Newton** — Android 2.3.1 (API 9), OReader / AlReader
  (`com.neverland.oreader`)

Вторая сторона при проверке — **Xteink X4** с прошивкой CrossPoint
(клиент KOReader Sync).

---

## Как это работает

```
База AlReader (RLIST: POS, SZ)
        │
        │  bookpos: разбор EPUB → таблица узлов → XPointer
        ▼
/body/DocFragment[13]/body/p[1]/text()[1].50
        │
        │  kosync.sh: HTTP PUT/GET с заголовками x-auth-user / x-auth-key
        ▼
KoSync-сервер  ⇄  устройство с KOReader / CrossPoint
```

1. **AlReader / OReader** хранит позицию в
   `/data/data/com.neverland.oreader/databases/alreader.db`, таблица `RLIST`:
   `POS` — смещение в символах, `SZ` — общая длина текста книги.
2. **`bookpos`** — небольшая программа на C: разбирает EPUB, строит таблицу
   узлов (фрагмент spine → путь элемента → смещения в кодпоинтах) и
   переводит `POS` ⇄ XPointer.
3. Поскольку AlReader и `bookpos` считают текст немного по-разному
   (`SZ` против общего числа модели), смещения пересчитываются между двумя
   системами координат.
4. **`kosync.sh`** общается с сервером по обычному HTTP. `x-auth-key` —
   это `md5(пароль)`, как в KOReader.
5. **Приложение** — обёртка над скриптом: показывает локальный и серверный
   прогресс **до** любых действий, имеет экран настроек (сервер, пользователь,
   пароль) и спрашивает подтверждение перед записью.

---

## Требования

### Устройство

- Android **2.3+** (проверено на 2.3.1 / API 9), ARMv7
- **Root** (`su`) — без него нельзя прочитать базу читалки и записать позицию
- Wi-Fi; **только обычный HTTP** — busybox из Android 2.3 не умеет TLS,
  поэтому сервер синхронизации должен быть доступен по `http://`

### Читалка

- **AlReader / OReader**, пакет `com.neverland.oreader`
  (на Onyx Boox это штатный `/system/app/AlReader.apk`)
- Книги в **EPUB**. FB2 не поддерживается: для него нет преобразования в XPointer

### Бинарники на устройстве

- `sqlite3` — статическая сборка под ARM (чтение/запись `alreader.db`)
- `bookpos` — статическая сборка под ARM из `device/bookpos.c`

Оба кладутся в `/data/local/tmp/` и должны быть исполняемыми.

### Сервер синхронизации

Любой kosync-сервер (свой или публичный). Нужны: адрес, пользователь, пароль
(пароль хешируется в `md5` локально).

### Второе устройство для чтения

KOReader или прошивка с поддержкой KOReader Sync и XPointer — например
**CrossPoint** на Xteink X4/X3.

### Инструменты сборки (только если пересобирать)

- `zig` — кросс-компиляция `bookpos` под ARM
- Android build-tools (`aapt`, `zipalign`), `dx`, компилятор Eclipse (`ecj`),
  JDK 8 — для APK (`app/build.ps1`)

---

## Установка

1. **Скопировать вспомогательные бинарники** и сделать их исполняемыми:

   ```sh
   adb push sqlite3 /data/local/tmp/sqlite3
   adb push bookpos /data/local/tmp/bookpos
   adb shell su -c "chmod 755 /data/local/tmp/sqlite3 /data/local/tmp/bookpos"
   ```

2. **Установить скрипт синхронизации:**

   ```sh
   adb push device/kosync.sh /data/local/tmp/kosync.sh
   adb shell su -c "chmod 755 /data/local/tmp/kosync.sh"
   ```

3. **Создать файл настроек** из примера (его читает скрипт, и его же
   записывает экран настроек приложения):

   ```sh
   adb shell su -c "mkdir -p /sdcard/oreader-kosync"
   adb push device/kosync.conf.example /sdcard/oreader-kosync/kosync.conf
   ```

   Затем отредактировать:

   ```sh
   SERVER='http://адрес-сервера'
   AUTH_USER='ваш_логин'
   AUTH_KEY='md5_от_пароля'
   ```

4. **(Необязательно) Собрать и установить приложение:**

   ```powershell
   powershell -ExecutionPolicy Bypass -File app\build.ps1 -Install
   ```

   Скрипту сборки нужны Android build-tools, `ecj`, `dx` и JDK 8 — поправьте
   пути в начале `build.ps1` под свою машину.

---

## Использование

### В приложении

- Главный экран показывает книгу, локальный процент и **процент на сервере**
  (с именем устройства и временем последней записи).
- **Отправить** — записать текущую локальную позицию на сервер.
- **Загрузить** — применить серверную позицию локально (с подтверждением и
  показом обоих процентов).
- **Настройки сервера** — адрес, пользователь, пароль (приложение само считает
  `md5`; строка из 32 hex-символов принимается как готовый ключ; пустое поле
  оставляет прежний ключ).

### Из терминала

```sh
sh /data/local/tmp/kosync.sh server   # показать локальный и серверный прогресс
sh /data/local/tmp/kosync.sh push     # отправить последнюю открытую книгу
sh /data/local/tmp/kosync.sh pull     # применить серверную позицию
sh /data/local/tmp/kosync.sh status   # подробный статус
```

`push`/`pull` принимают необязательное имя книги (`push 609279.epub`) или `all`.

> Перед `pull` закройте книгу в OReader: пока книга на экране, скрипт
> отказывается писать в базу, иначе читалка перезапишет новую позицию из памяти.

---

## Структура проекта

```
app/                    приложение для Android (Java, API 9)
  AndroidManifest.xml
  build.ps1             сборка: aapt + ecj + dx + apksigner
  src/ru/local/oreadersync/MainActivity.java
device/
  kosync.sh             скрипт синхронизации (push / pull / status / server)
  kosync.conf.example   шаблон настроек
  bookpos.c             конвертер «позиция ⇄ XPointer»
  miniz/                распаковка zlib, используется bookpos (MIT)
```

## Сборка bookpos

```sh
# для проверки на компьютере
zig cc -O2 -I device/miniz device/bookpos.c device/miniz/miniz.c -o bookpos

# ARM, статически, для читалки
zig cc -target arm-linux-musleabihf -mcpu=cortex_a8 -O2 -static -fno-pie -no-pie \
       -I device/miniz device/bookpos.c device/miniz/miniz.c -o bookpos
```

Команды: `info`, `table`, `p2x <позиция>`, `x2p <xpath>`.

---

## Ограничения

- **Только EPUB.** Для FB2 и других форматов преобразования в XPointer нет.
- **Проценты у устройств разные.** CrossPoint считает процент по байтам файлов
  spine, AlReader — по числу символов. Переносится **позиция**, а проценты —
  только для показа.
- **Разница в ±1 страницу — это норма.** Читалки по-разному разбивают текст на
  страницы (шрифт, кегль, поля), поэтому одна и та же позиция попадает на
  разные страницы.
- **Только обычный HTTP** на Android 2.3 — TLS в штатном busybox нет.
- Вторая сторона должна понимать XPointer формата KOReader
  (`/body/DocFragment[N]/body/.../text()[k].off`).

## Приватность

В репозитории нет ни учётных данных, ни адресов серверов, ни личных данных.
И приложение, и скрипт берут настройки из `/sdcard/oreader-kosync/kosync.conf`
на самом устройстве. Книги в репозиторий не входят.

## Лицензия

MIT. Каталог `device/miniz` — библиотека miniz (public domain / MIT),
см. её `LICENSE`.
