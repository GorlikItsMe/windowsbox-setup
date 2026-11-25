# win-setup — Windows 11 w jednym poleceniu

Jeden plik PowerShell, który na świeżym Windows 11 robi porządek w systemie i stawia
cały toolchain: git, Node, Python, edytory, CLI, Visual Studio.

```powershell
powershell -c "irm https://raw.githubusercontent.com/<user>/<repo>/main/win-setup.ps1 | iex"
```

Skrypt sam się podnosi do administratora (UAC), pyta o kilka rzeczy (ENTER = domyślna
opcja, czyli „tak, wszystko"), a potem leci bez nadzoru.

## Co się dzieje po kolei

| Faza | Co robi |
|---|---|
| 1. debloat | uruchamia **[Win11Debloat](https://github.com/Raphire/Win11Debloat)** (pobiera najnowsze wydanie, sprawdza SHA-256, `-RunDefaults -Silent`) |
| 2. settings | długie ścieżki (>260 znaków), Developer Mode, `ExecutionPolicy = RemoteSigned`, opcjonalnie strefa czasowa i WSL |
| 3. packages | instaluje pakiety przez `winget`, pomija to, co już jest |
| 4. post-config | `git config --global` (aliasy, editor, credential manager), klucz SSH ed25519 + ssh-agent, moduły PowerShell (`Terminal-Icons`, `posh-git`), globalne pakiety npm/bun, **noVNC + autostart T3 Code** |

Na końcu podaje podsumowanie, adres noVNC, public key SSH i przypomina o restarcie.

## Debloat = Win11Debloat, nie własna lista

Faza 1 nie ma własnych list aplikacji — deleguje do gotowego, utrzymywanego skryptu
[Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) (MIT):

1. pobiera najnowsze wydanie z GitHuba (`Win11Debloat.zip` + `SHA256SUMS`),
2. sprawdza sumę kontrolną, jeśli wydanie ją publikuje,
3. rozpakowuje do `%LOCALAPPDATA%\win-setup\Win11Debloat\`,
4. uruchamia `Win11Debloat.ps1 -RunDefaults -Silent` (osobny proces — on kończy się
   przez `Exit`), z `-CreateRestorePoint`, jeśli wybrałeś punkt przywracania.

Co to daje: usuwanie domyślnych apek, telemetria, reklamowe ID, podpowiedzi, Copilot,
widgety, Bing w wyszukiwaniu — wszystko aktualizowane razem z Win11Debloat, bez
kopiowania list do tego pliku.

`-Aggressive` dokłada flagi (lista w `$CONFIG.Debloat.AggressiveArgs`): Copilot,
Recall, Click to Do, widgets, chat, Xbox Game Bar/DVR, lokalizacja, Find My Device,
fast startup, delivery optimization.

Zawsze, niezależnie od `-Aggressive`, lecą Twoje osobiste flagi z
`$CONFIG.Debloat.PersonalArgs`: `-EnableEndTask` (zabijanie z taskbara),
`-ShowKnownFileExt`, `-RevertContextMenu` (stare menu kontekstowe), `-ExplorerToThisPC`,
`-ClearStart` (bez przypiętych śmieci).

Win11Debloat trzyma własne backupy rejestru w `%LOCALAPPDATA%\Win11Debloat\Backups`,
a swój log w `%LOCALAPPDATA%\win-setup\Win11Debloat.log`.

## Preflight i detekcja pakietów

Przed zmianami skrypt sprawdza dostęp do `api.github.com` i CDN winget oraz wolne
miejsce na dysku (ostrzeżenie poniżej 15 GB — VS + Docker chcą ~30 GB).

Faza pakietów robi `winget source update`, sprawdza wersję winget i wykrywa
zainstalowane pakiety po **ID w tabeli**, nie po komunikacie „No installed package
found" — ten komunikat jest tłumaczony, więc na polskim Windowsie stara wersja
fałszywie uznawała pakiety za obecne.

## Git i SSH

`git config --global` ustawia: `init.defaultBranch`, `core.autocrlf`, `core.longpaths`,
`pull.rebase=false`, `fetch.prune`, `core.editor` (`code --wait`),
`credential.helper manager` oraz aliasy `st`, `co`, `br`, `lg`, `last`, `undo`.

Jeśli nie ma `~/.ssh/id_ed25519`, skrypt generuje klucz ed25519 (bez passphrase,
komentarz = Twój e-mail), zawęża ACL katalogu `.ssh` do Twojego konta, ustawia
`ssh-agent` na Automatic i ładuje klucz. Na końcu wypisuje public key do wklejenia
na GitHubie.

## Zdalny dostęp: noVNC po Tailscale

Trzy elementy, wszystkie stawiane automatycznie:

| Element | Rola |
|---|---|
| **TightVNC** (`GlavSoft.TightVNC`) | serwer VNC jako usługa Windows, **tylko loopback** (`SET_LOOPBACKONLY=1`), **bez hasła** |
| **websockify** (venv w `%ProgramData%\win-setup\novnc\venv`) | most WebSocket ↔ VNC, nasłuchuje **tylko na adresie Tailscale** |
| **noVNC 1.7.0** (`%ProgramData%\win-setup\novnc\web`) | klient w przeglądarce, serwowany przez websockify |

Dostęp: `http://<tailnet-host>:6080/` — adres jest wypisywany na końcu setupu
i zapisany w `%ProgramData%\win-setup\novnc\url.txt`. noVNC nie ma własnego
`index.html`, więc skrypt dopisuje mały redirect na `vnc.html?autoconnect=true&resize=scale`
— dzięki temu działa sam korzeń, bez pamiętania ścieżki.

Autostart: zadanie **„win-setup noVNC"** przy starcie systemu (konto SYSTEM, bez okna).
Wrapper czeka do 5 minut, aż Tailscale wstanie, i dopiero wtedy startuje websockify.
Log: `%ProgramData%\win-setup\novnc\novnc.log`.

Firewall: reguła wpuszczająca port 6080 **tylko z `100.64.0.0/10`** (tailnet) i reguła
blokująca 5900 z zewnątrz. VNC i tak słucha wyłącznie na `127.0.0.1`, więc bez
Tailscale nie ma do niego drogi. Ruch jest szyfrowany przez WireGuard — dlatego
brak TLS na samym noVNC.

**Bez hasła, świadomie.** Uwierzytelnianie VNC jest wyłączone (`UseVncAuthentication=0`,
skrypt wymusza to też w rejestrze po instalacji, bo MSI bywa niespójne). Kto jest
w Twoim tailnecie, ten może przejąć pulpit — jeśli to za dużo, włącz „Require VNC
authentication" w TightVNC Server i dopisz `&password=...` do adresu.

## Autostart T3 Code

T3 Code nie ma wbudowanego „start minimized", więc skrypt tworzy launcher
`%LOCALAPPDATA%\win-setup\T3CodeStartup\start-t3code-minimized.ps1` i skrót
**„T3 Code (minimized)"** w `shell:startup`. Launcher:

- nie robi nic, jeśli T3 Code już działa,
- czeka na okno większe niż 500×350 (pomija splash),
- minimalizuje je przez Win32 `ShowWindow`, raz na okno,
- loguje wszystko do `...\T3CodeStartup\startup.log`.

Wyłączenie: usuń skrót z `shell:startup` albo `-NoT3Autostart`.

## Co instaluje

**Core (zawsze):**

| Kategoria | Pakiety |
|---|---|
| podstawa | Git, GitHub CLI, PowerShell 7, Windows Terminal, 7zip, WinDirStat |
| edytory / AI | VS Code, Cursor, Claude Code (`claude`), opencode (`opencode`), Antigravity |
| menedżery | pnpm, Bun |
| CLI | ripgrep, fd, fzf, jq, curl, ffmpeg, fastfetch |
| runtime | Node.js LTS, Python 3.15, uv, .NET SDK 8 |
| sieć / narzędzia | Tailscale, T3 Code |

**Optional** (domyślnie też instalowane — w menu można odznaczyć):
Chrome, VS Code Insiders, Claude Desktop oraz **Visual Studio 2022 Community**
z workloadami `ManagedDesktop` + `NetWeb`. Bez Dockera, Azure CLI, kubectl, Helm,
Terraform, WSL, PowerToys i Chocolatey — te świadomie wypadły.

Listę zmieniasz w bloku `$CONFIG` na górze pliku — to jedyne miejsce, które trzeba
edytować. Python jest przypięty do `3.15`, bo winget nie ma „latest"; gdy wyjdzie
3.16, zmień jedną linię.

## Menu

Przy uruchomieniu skrypt pyta (ENTER = to, co w `[NAWIASACH]`):

```
debloat Windows (Win11Debloat)                     [Y/n]
  aggressive (Copilot, Recall, widgets, Xbox bar)  [y/N]
install optional group                             [Y/n]
create a restore point first                       [Y/n]
remove OneDrive completely                         [y/N]
remote access: noVNC over Tailscale (TightVNC)     [Y/n]
start T3 Code minimized at login                   [Y/n]
set git user.name / user.email now                 [Y/n]
reboot when finished                               [y/N]
```

Samo ENTER = pełna instalacja z domyślnym debloatem, bez agresywnych dodatków.

## Parametry

| Parametr | Działanie |
|---|---|
| `-WhatIfOnly` | pełny podgląd, zero zmian, bez admina |
| `-Yes` | bez pytań, wszystkie domyślne |
| `-NoDebloat` | nie dotykaj Windows, tylko instaluj |
| `-Aggressive` | agresywny debloat |
| `-NoOptional` | tylko Core, bez Dockera/VS/Azure |
| `-RemoveOneDrive` | odinstaluj OneDrive |
| `-NoRemote` | bez TightVNC/noVNC (zdalny dostęp zostaje wyłączony) |
| `-NoT3Autostart` | bez autostartu T3 Code |
| `-OnlyRemote` | tylko zdalny dostęp + autostart T3 (bez debloatu i pakietów) |
| `-NoRestorePoint` | nie rób punktu przywracania |
| `-Reboot` | restart po zakończeniu |
| `-Force` | reinstaluj to, co już jest |
| `-Revert` | otwiera okno przywracania Win11Debloat (jego własne backupy rejestru) |

Z pliku lokalnego:

```powershell
.\win-setup.ps1 -WhatIfOnly
.\win-setup.ps1
.\win-setup.ps1 -Yes -NoOptional
.\win-setup.ps1 -Revert
```

## Logi, backup, cofanie

Wszystko ląduje w `%LOCALAPPDATA%\win-setup\`:

- `log-*.log` — przebieg tego skryptu: każda zmiana, każdy błąd, każdy pakiet,
- `Win11Debloat.log` — transkrypt fazy debloatu,
- `novnc\` (w `%ProgramData%\win-setup`) — venv, pliki noVNC, `url.txt`, `novnc.log` (log systemowy, poza profilem),
- `T3CodeStartup\` — launcher + `startup.log`,
- `answers.json` — odpowiedzi z menu przekazane do procesu z uprawnieniami admina.

Cofanie debloatu robi Win11Debloat: `-Revert` otwiera jego okno, w którym wybierasz
„Restore backup". Backupy rejestru leżą w `%LOCALAPPDATA%\Win11Debloat\Backups`.
Usuniętych aplikacji to nie przywróci — instalujesz je ze Store.

## Publikacja

Repo: `GorlikItsMe/windowsbox-setup` (prywatne). Są w nim tylko `win-setup.ps1`
i `README.md`.

W linii `$SourceUrl` skryptu jest już wpisany surowy adres:

```powershell
$SourceUrl = 'https://raw.githubusercontent.com/GorlikItsMe/windowsbox-setup/main/win-setup.ps1'
```

Skrypt używa go tylko wtedy, gdy jest odpalony przez `irm | iex` — wtedy nie ma pliku
na dysku, więc ściąga własną kopię do `%LOCALAPPDATA%\win-setup\` i dopiero ją uruchamia
z uprawnieniami administratora.

**Prywatne repo = brak jednej linijki.** `raw.githubusercontent.com` wymaga wtedy
nagłówka `Authorization`, więc `powershell -c "irm <url> | iex"` nie zadziała na
czystej maszynie. Dwie opcje:

```powershell
# 1) upublicznić repo (nic w pliku nie trzeba zmieniać)
gh repo edit GorlikItsMe/windowsbox-setup --visibility public

# 2) zostać przy prywatnym i klonować na maszynie docelowej
gh auth login
gh repo clone GorlikItsMe/windowsbox-setup
.\windowsbox-setup\win-setup.ps1
```

Przy publicznym repo test to: `powershell -c "irm https://raw.githubusercontent.com/GorlikItsMe/windowsbox-setup/main/win-setup.ps1 | iex"`.

**Plik musi być zapisany jako UTF-8 bez BOM.** Plik z BOM-em wywala się przy
`irm | iex` (PowerShell nie rozpoznaje wtedy nawet `#Requires`). Edytory, które
dodają BOM: Notatnik („UTF-8 z BOM"), część wtyczek VS Code. Bezpiecznie: zapis
w VS Code jako „UTF-8", ewentualnie `Set-Content -Encoding utf8NoBOM` w pwsh 7.

## Czego skrypt nie zrobi

- nie aktywuje Windowsa (potrzebny prawdziwy klucz),
- nie przenosi plików, kluczy SSH, tokenów, haseł ani danych z WSL,
- nie odtwarza ustawień aplikacji (VS Code, Terminal, VS) — tylko je instaluje,
- nie instaluje apek ze Store, których nie ma w winget,
- debloat to zewnętrzny Win11Debloat — jego zakres zmienia się między wydaniami.

Po instalacji warto: otworzyć nowy terminal (nowy PATH), `gh auth login`,
`claude` / `opencode` i zalogować się, `tailscale up`.
