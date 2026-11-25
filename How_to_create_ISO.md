# How to create a bootable Windows ISO with `autounattend.xml`

This document explains how to embed an `autounattend.xml` answer file into a
Windows 11 installation ISO, and how to reproduce the whole process from scratch.

> All examples use **relative paths** — run every command from the folder that
> already contains the source `.iso` and `autounattend.xml` files.

---

## What this does (summary)

1. Mount the original ISO and copy its entire contents to a working folder.
2. Insert `autounattend.xml` into the **root** of the image.
3. Rebuild a bootable ISO (BIOS/Legacy **and** UEFI) using `oscdimg`.
4. Optionally replace the original ISO with the new one.

> The `autounattend.xml` is fully self-contained: the PowerShell scripts
> (`GetComputerName.ps1`, `Specialize.ps1`, `DefaultUser.ps1`, `FirstLogon.ps1`, …)
> are embedded inside the `<Extensions>` section and are extracted to disk
> automatically during Windows Setup (`specialize` pass, Order 1).

---

## Requirements

- **`oscdimg.exe`** — from the Windows ADK (Deployment Tools), or install it
  standalone via the package manager:

  ```powershell
  winget install Microsoft.OSCDIMG
  ```

- **PowerShell** (built into Windows).
- **~20 GB of free disk space** (the ISO is ~9 GB, plus a ~9 GB working copy).

---

## Step 1 — Working variables

```powershell
$iso     = 'windows_11_26h2_with_my_script.iso'   # source ISO
$xml     = 'autounattend.xml'                      # answer file
$stage   = '_iso_build\iso'                        # working folder
$outIso  = 'windows_11_26h2_unattended.iso'        # new ISO (temporary name)
$oscdimg = 'oscdimg.exe'                           # or its full path if not on PATH
```

---

## Step 2 — Mount the original ISO

```powershell
$m = Mount-DiskImage -ImagePath $iso -PassThru
$drive = ($m | Get-Volume).DriveLetter   # e.g. E:
```

---

## Step 3 — Copy the ISO contents to a working folder

```powershell
New-Item -ItemType Directory -Force -Path $stage | Out-Null
robocopy "${drive}:\" $stage /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH
```

> `robocopy` copies everything, including `sources\install.wim` and the boot
> files `boot\etfsboot.com` and `efi\microsoft\boot\efisys.bin`.

---

## Step 4 — Insert `autounattend.xml` into the root

```powershell
Copy-Item -Path $xml -Destination (Join-Path $stage 'autounattend.xml') -Force
```

The file **must** be named exactly `autounattend.xml` and live in the root of
the media — Windows Setup then reads it automatically.

---

## Step 5 — Unmount the original ISO

```powershell
Dismount-DiskImage -ImagePath $iso
```

---

## Step 6 — Rebuild the bootable ISO

```powershell
$bootdata = "2#p0,e,b$stage\boot\etfsboot.com#pEF,e,b$stage\efi\microsoft\boot\efisys.bin"

& $oscdimg -m -o -u2 -udfver102 -lCCCOMA_X64FRE_PL-PL_DV9 "-bootdata:$bootdata" $stage $outIso
```

| Option | Meaning |
|--------|---------|
| `-m` | ignore the maximum size limit (required for images > 4 GB) |
| `-o` | optimization — duplicate files are stored only once |
| `-u2` | UDF-only file system (like original Windows media) |
| `-udfver102` | UDF revision 1.02 |
| `-lCCCOMA_X64FRE_PL-PL_DV9` | volume label (keep the original, optional) |
| `-bootdata:2#...` | dual boot: `p0` (BIOS/Legacy) + `pEF` (UEFI) |

---

## Step 7 — Verify the result

```powershell
$m2 = Mount-DiskImage -ImagePath $outIso -PassThru
$d2 = ($m2 | Get-Volume).DriveLetter

Test-Path "$d2`:\autounattend.xml"               # True
Test-Path "$d2`:\boot\etfsboot.com"              # True
Test-Path "$d2`:\efi\microsoft\boot\efisys.bin"  # True
Test-Path "$d2`:\sources\install.wim"            # True

Dismount-DiskImage -ImagePath $outIso
```

---

## Step 8 — Replace the original ISO (optional)

```powershell
Remove-Item $iso -Force
Rename-Item $outIso $iso
```

> If the original file is locked (e.g. by Windows Defender, Search Indexer or
> File Explorer after mounting), wait a moment or close Explorer windows and try
> again — or simply keep the new ISO under `windows_11_26h2_unattended.iso`.

---

## Step 9 — Clean up (optional)

```powershell
Remove-Item '_iso_build' -Recurse -Force
```

---

## Notes

- The answer file in this project comes from the
  [unattend-generator (schneegans.de)](https://schneegans.de/windows/unattend-generator/) tool.
- The `<Extensions>` section contains embedded PowerShell scripts that Windows
  Setup extracts to `C:\Windows\Setup\Scripts\` during installation — you do
  **not** need to add them to the ISO separately.
- To write the finished ISO to a USB drive, use **Rufus** or the
  *Media Creation Tool*.
