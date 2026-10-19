# ShiftDrop

Konwersja plików na Macu jednym gestem: **przeciągnij plik → wciśnij ⇧ Shift → upuść na format**.

Podczas przeciągania dowolnego pliku (z Findera, biurka, Zdjęć, przeglądarki) wciśnięcie Shift otwiera pod kursorem
koło z formatami. Drugi Shift przełącza na koło narzędzi. Wynik ląduje obok oryginału, a mały dymek potwierdza zapis
(kliknięcie pokazuje plik w Finderze). Aplikacja siedzi w pasku menu, nie ma ikony w Docku.

## Co potrafi

| Plik | Koło formatów | Koło narzędzi (drugi ⇧) |
| --- | --- | --- |
| **Obraz** (JPG, PNG, HEIC, WEBP, AVIF, TIFF, BMP, GIF…) | PNG, JPG, WEBP, HEIC, TIFF, AVIF, BMP, PDF, TXT i DOCX (OCR) | Compress, Metadata, Edit, Annotate, Add BG, Crop, Redact, Cut Out (macOS 14+) |
| **PDF** | DOCX, JPG, PNG, TXT (skany przez OCR) | Compress, Merge (kilka plików), Split, Rotate, Protect (hasło), Metadata |
| **Dokument** (TXT, MD, RTF, DOCX, DOC, ODT, HTML) | PDF, DOCX, RTF, HTML, ODT, TXT | — |
| **Wideo** (MOV, MP4, M4V) | MP4, MOV, HEVC, GIF, M4A (dźwięk) | Compress, Mute, Snapshot |
| **Audio** (WAV, AIFF, M4A, MP3, FLAC, CAF) | M4A, WAV, AIFF, FLAC | Compress |

- Kilka plików naraz: akcja wykona się dla każdego, a obrazy → PDF łączą się w jeden dokument.
- Edytory **Crop**, **Add BG**, **Edit**, **Annotate**, **Redact** i **Metadata** otwierają okno z podglądem,
  tak jak na nagraniu (proporcje Free / 1:1 / 16:9 / 9:16 / 4:3 / 3:4, tło z gradientem, padding, zaokrąglenia, cień…).
- Wszystko działa lokalnie, na frameworkach Apple (ImageIO, PDFKit, Vision, AVFoundation, Core Image). Nic nie jest
  wysyłane do internetu.
- WEBP i AVIF pojawiają się w kole tylko wtedy, gdy macOS potrafi je zapisać. Jeśli ich brakuje, doinstaluj enkodery:
  `brew install webp libavif` – ShiftDrop wykryje je sam.

## Instalacja

### Opcja A – zbuduj u siebie (zalecane)

Wymagania: macOS 13 Ventura lub nowszy oraz Xcode 16 (albo Command Line Tools ze Swift 6).

```bash
git clone -b claude/shiftdrop-mac-app https://github.com/zharne6967/taste-skill.git
cd taste-skill/apps/ShiftDrop
./scripts/build-app.sh --install
```

Skrypt kompiluje aplikację, kopiuje `ShiftDrop.app` do `/Applications` i ją uruchamia. Zbudowana lokalnie aplikacja
nie dostaje flagi kwarantanny, więc Gatekeeper nie protestuje.

### Opcja B – gotowa paczka z GitHub Actions

Każdy push buduje uniwersalną aplikację (Apple silicon + Intel) w workflow **ShiftDrop (macOS app)**. Pobierz
artefakt `ShiftDrop-app`, rozpakuj i przenieś `ShiftDrop.app` do Aplikacji. Aplikacja jest podpisana ad-hoc (bez konta
Apple Developer), więc przy pierwszym uruchomieniu macOS ją zablokuje:

- otwórz **Ustawienia systemowe → Prywatność i ochrona** i kliknij **Otwórz mimo to**, albo
- w Terminalu: `xattr -dr com.apple.quarantine /Applications/ShiftDrop.app`

## Pierwsze uruchomienie

- Pojawi się okno „How It Works”, a w pasku menu ikona koła.
- **Nie są potrzebne uprawnienia Dostępności ani Monitorowania wejścia.** ShiftDrop tylko odczytuje stan przycisku
  myszy, klawisza Shift i schowka przeciągania, i to wyłącznie w trakcie przeciągania.
- Przy pierwszym zapisie na Biurku lub w Dokumentach macOS zapyta o dostęp do tego folderu – zezwól.

## Menu w pasku

- **Enabled** – włącza/wyłącza reakcję na Shift.
- **Save Results** – obok oryginału albo zawsze w Pobranych.
- **Reveal Results in Finder** – po każdej konwersji zaznacza wynik w Finderze.
- **Launch at Login** – start razem z systemem (działa najlepiej, gdy aplikacja jest w `/Applications`).
- **Open File…** – wybierz plik bez przeciągania, a potem kliknij segment koła.

## Jak to działa w środku

```
Sources/ShiftDrop
├── App.swift              pasek menu, ustawienia, tryby deweloperskie
├── Wheel/                 wykrywanie przeciągania + Shift, panel z kołem, trafianie w segmenty
├── Engine/                konwersje: obrazy, PDF, dokumenty, wideo/audio, renderery edytorów
├── UI/                    edytory (Crop, Add BG, Edit, Annotate, Redact, Metadata), dymek, ekran powitalny
└── Dev/                   self-test i zrzuty interfejsu dla CI
```

- `DragMonitor` startuje przy każdym kliknięciu (globalny monitor `leftMouseDown`) i przez czas trzymania przycisku
  co 1/60 s sprawdza schowek przeciągania oraz Shift. Gdy Shift zostanie wciśnięty w trakcie przeciągania plików,
  pod kursorem pojawia się nieaktywujący się panel, który przyjmuje upuszczenie.
- Pliki z aplikacji, które przekazują „obietnice plików” (Zdjęcia, Safari), są odbierane do katalogu tymczasowego,
  a wynik trafia do Pobranych.

## Testy

```bash
swift build -c release
.build/release/ShiftDrop --selftest /tmp/shiftdrop-selftest   # generuje próbki i przepuszcza je przez każdą akcję
.build/release/ShiftDrop --snapshots /tmp/shiftdrop-ui        # renderuje koło i edytory do PNG
```

CI (`.github/workflows/shiftdrop-macos.yml`) robi to samo na macOS 15 i publikuje aplikację, zrzuty oraz log testów.
