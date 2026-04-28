# 📁 Sync Media Organizer (PowerShell)

A powerful PowerShell script to **sync, deduplicate, and organize media files** (images & videos) across directories.

It supports **EXIF metadata, filename date extraction, and automatic media separation**, making it ideal for messy backups (phones, cloud, WhatsApp, etc.).

---

## 🚀 Features

* 📸 **EXIF Date Taken support** (accurate for photos)
* 📂 **Multiple source directories** in a single run
* 📛 **Filename date extraction** (e.g. `IMG_20160421.jpg`)
* 🧠 Smart fallback:

  * EXIF → Filename → CreationTime → LastWriteTime
* 🖼 **Automatic media separation**

  * Images → `Images/YYYY/MM`
  * Videos → `Videos/YYYY/MM`
* 📅 Organize by **Year / Month**
* 🔁 **Deduplication system**
* 📏 Optional size-based replacement
* 🚚 **Copy by default or move with a switch**
* 🧪 **Dry-run mode**
* 📜 Logging support
* 🔢 Process **limited number of files**
* 🚫 Ignore duplicate suffix like `(1)`, `(2)`

---

## 📂 Output Structure

```
OrganizedMedia/
  Images/
    2016/
      04/
  Videos/
    2020/
      12/
```

---

## ⚙️ Parameters

| Parameter                | Type     | Description                               |
| ------------------------ | -------- | ----------------------------------------- |
| `-Source`                | string[] | One or more source directories            |
| `-Targets`               | string[] | Target directories (for dedup comparison) |
| `-Output`                | string   | Output directory                          |
| `-MoveFiles`             | switch   | Move files instead of copying             |
| `-DryRun`                | switch   | Simulate without copying or moving        |
| `-LogFile`               | string   | Log file path                             |
| `-UseName`               | switch   | Use filename for matching                 |
| `-UseDate`               | switch   | Use file date for matching                |
| `-UseSize`               | switch   | Use size for replacement logic            |
| `-IgnoreDuplicateSuffix` | switch   | Ignore files like `file(1).jpg`           |
| `-OrganizeByDate`        | switch   | Enable YYYY/MM structure                  |
| `-MaxFiles`              | int      | Limit number of processed files           |
| `-UseFileNameDate`       | switch   | Extract date from filename                |
| `-SeparateMedia`         | switch   | Separate Images and Videos                |

---

## 🧪 Usage Examples

### 🔍 Dry Run (Safe Test)

```powershell
.\sync-media.ps1 `
  -Source "E:\cloud","F:\camera-roll" `
  -Targets "D:\Photos","D:\Videos" `
  -Output "D:\OrganizedMedia" `
  -OrganizeByDate `
  -SeparateMedia `
  -UseFileNameDate `
  -DryRun
```

---

### ⚡ Real Execution

```powershell
.\sync-media.ps1 `
  -Source "E:\cloud","F:\camera-roll" `
  -Targets "D:\Photos","D:\Videos" `
  -Output "D:\OrganizedMedia" `
  -OrganizeByDate `
  -SeparateMedia `
  -UseFileNameDate
```

### 🚚 Move Files Instead of Copying

```powershell
.\sync-media.ps1 `
  -Source "E:\cloud","F:\camera-roll" `
  -Targets "D:\Photos","D:\Videos" `
  -Output "D:\OrganizedMedia" `
  -OrganizeByDate `
  -SeparateMedia `
  -UseFileNameDate `
  -MoveFiles
```

---

### 🔢 Process Only 100 Files

```powershell
-MaxFiles 100
```

---

## 🧠 How Date Detection Works

Priority order:

1. 📸 EXIF (Date Taken)
2. 📛 Filename (if enabled)
3. 📁 CreationTime
4. 🕒 LastWriteTime

---

## 📝 Example Log Output

```
DATE: IMG_1234.jpg | Selected=2016-04-21 | Created=2026-04-28 | Modified=2004-12-18
COPY: E:\cloud\IMG_1234.jpg -> D:\OrganizedMedia\Images\2016\04\IMG_1234.jpg
```

---

## ⚠️ Known Limitations

* Files without EXIF or date in filename fall back to filesystem dates
* Some apps (e.g. WhatsApp, ZIP tools) strip metadata
* Windows “Date” column may not match filesystem timestamps

---

## 🛠 Requirements

* Windows PowerShell 5+ or PowerShell 7+
* No external dependencies

---

## 🔮 Future Improvements

* 📅 WhatsApp filename detection (`IMG-YYYYMMDD-WAxxxx`)
* 🧹 Fix corrupted filenames (`_25C2_`)
* ⚡ Parallel processing for performance
* 🧠 AI-based duplicate detection

---

## 🤝 Contributing

Pull requests are welcome. For major changes, please open an issue first.

---

## 📜 License

MIT License
