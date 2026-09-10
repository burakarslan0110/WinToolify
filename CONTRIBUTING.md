# Contributing to WinToolify

Thanks for taking the time to read this. It's the short version of what CI checks anyway, so five minutes now saves a round trip later.

Türkçe için [aşağıya](#wintoolifye-katkı) bak.

## Before you start

Open an issue first for anything bigger than a fix, a new catalogue entry, a new screen, or a new assistant tool included, since catalogue names freeze the moment they ship and are worth agreeing on beforehand. Small things like a wrong consequence line, a broken translation, or a row reporting the wrong state need no issue at all.

## Setup

You need Windows, Windows PowerShell 5.1 (or PowerShell 7), Pester 5.9.1, and PSScriptAnalyzer 1.25.0. Nothing else.

```powershell
Install-Module -Name Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
```

## The one command

```powershell
.\tools\Invoke-WtChecks.ps1
```

This is the gate. It builds `src/` into `dist/WinToolify.ps1`, parses the result, runs the PowerShell 5.1 and 7.0 compatibility rules, then runs the full Pester suite, and CI runs exactly this and nothing more. Don't call `Invoke-Pester` yourself, the tests are written against the built file. Scope a run while you work with `-TestPath`:

```powershell
.\tools\Invoke-WtChecks.ps1 -TestPath .\tests\Blocklist.Tests.ps1
```

## Rules the build and tests enforce

- **Edit `src/`, never `dist/`.** The build writes `dist/WinToolify.ps1`, it isn't checked in.
- **Keep the layer order.** Sources concatenate in ordinal path order, so a call may only point downward. `40-catalogs/` can't call into `80-screens/`.
- **One function, one file.** The build fails if the same function shows up twice.
- **Comments are `.SYNOPSIS` blocks**, no commentary in the body. Every file opens with a one-line description and a `# Covered by:` line naming its tests, and the SYNOPSIS explains the why, in English.
- **Translations stay ASCII.** Both `en.ps1` and `tr.ps1` under `src/10-i18n/` hold ASCII-folded strings, Turkish without diacritics, so the file parses the same under any codepage.
- **Catalogue names and package ids are frozen.** Once a `Name` or `Id` ships, exported profiles and undo records are written against it. Add a new entry instead of renaming an old one.
- **Catalogues are data, screens compose.** A file under `40-catalogs/` returns objects and reads nothing live.
- **Every entry carries a risk tag**, `SAFE`, `CAUTION`, or `ADVANCED`, and anything above `SAFE` needs a plain-language consequence line saying what stops working.
- **Capture state before the change, never after.** A reversible change writes its pre-change state to an undo record before it runs, not once it's done.
- **Removal writes the Windows default back**, deleting the key outright is only right when the default actually is absent. No known default means mark it not removable rather than guessing.
- **Filter by OS.** A Windows 11 only row shouldn't show up on Windows 10.

## Tests

Add or update tests with the change. Every source file names its coverage at the top, and a new function with no test won't get past review. Prefer testing pure functions directly over mocking a whole screen, and check `tests/` before renaming an identifier or a literal a function already uses, since a few guard tests read function source text directly.

## Pull requests

Target `v2-dev`, not `main`. `main` only takes merged pull requests, and a push to it cuts a release. Keep one concern per pull request, say what changed and why, and call out any row whose risk tag or consequence text moved.

Labels on the merged PR pick the release:

| Label | Effect |
|---|---|
| `release:major` | Raises the major version |
| `release:minor` | Raises the minor version |
| `release:skip` | Merges with no release |
| none | Patch release |

---

# WinToolify'ye katkı

Bu dosyayı okumaya vakit ayırdığın için teşekkürler. CI zaten aynı şeyleri denetliyor, o yüzden burayı bir kez okumak sana sonradan bir tur kaybettirmez.

İngilizcesi için [yukarıya](#contributing-to-wintoolify) bak.

## Başlamadan önce

Bir düzeltmeden büyük her şey için önce issue aç. Yeni bir katalog girdisi, yeni bir ekran veya yeni bir asistan aracı da buna dahil, çünkü katalog adları yayınlandığı anda donuyor ve önceden konuşulmaya değer. Yanlış bir sonuç satırı, bozuk bir çeviri veya durumu yanlış raporlayan bir satır gibi küçük şeyler için issue gerekmiyor.

## Kurulum

Windows, Windows PowerShell 5.1 (veya PowerShell 7), Pester 5.9.1 ve PSScriptAnalyzer 1.25.0 yeterli, başka bir şey gerekmiyor.

```powershell
Install-Module -Name Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
```

## Tek komut

```powershell
.\tools\Invoke-WtChecks.ps1
```

Kapı bu. `src/` klasörünü `dist/WinToolify.ps1` olarak derliyor, sonucu ayrıştırıyor, PowerShell 5.1 ve 7.0 uyumluluk kurallarını çalıştırıyor, sonra tüm Pester paketini koşturuyor. CI de tam olarak bunu yapıyor, fazlasını değil. `Invoke-Pester`'ı kendin çağırma, testler derlenmiş dosyaya karşı yazıldı. Çalışırken kapsamı daraltmak için `-TestPath` ver:

```powershell
.\tools\Invoke-WtChecks.ps1 -TestPath .\tests\Blocklist.Tests.ps1
```

## Derlemenin ve testlerin dayattığı kurallar

- **`src/` içinde çalış, `dist/` içinde asla.** Derleme `dist/WinToolify.ps1`'i yazar, depoda durmaz.
- **Katman sırasını koru.** Kaynaklar sıralı yol düzeninde birleşir, bir çağrı sadece aşağıyı gösterebilir. `40-catalogs/` içinden `80-screens/` çağrılmaz.
- **Bir fonksiyon, bir dosya.** Aynı fonksiyon iki yerde tanımlanırsa derleme düşer.
- **Yorumlar `.SYNOPSIS` bloklarıdır**, gövdede yorum olmaz. Her dosya tek satırlık bir açıklamayla ve kendi testlerini adıyla sayan bir `# Covered by:` satırıyla açılır, "neden" sorusunun cevabı SYNOPSIS içinde İngilizce yazılır.
- **Çeviriler ASCII kalır.** `src/10-i18n/` altındaki `en.ps1` ve `tr.ps1` ASCII'ye indirgenmiş metinler tutar, Türkçe aksansız girer, böylece dosya her kod sayfasında aynı ayrışır.
- **Katalog adları ve paket kimlikleri donmuş durumdadır.** Bir `Name` veya `Id` yayınlandıktan sonra dışa aktarılmış profiller ve geri alma kayıtları ona göre yazılır. Eskisini yeniden adlandırmak yerine yeni bir girdi ekle.
- **Kataloglar veridir, ekranlar birleştirir.** `40-catalogs/` altındaki bir dosya nesne döndürür, canlı hiçbir şey okumaz.
- **Her girdi bir risk etiketi taşır**, `SAFE`, `CAUTION` veya `ADVANCED`, `SAFE` üstündeki her şey kullanıcının neyi kaybedeceğini düz sözcüklerle anlatan bir sonuç satırı ister.
- **Durumu değişiklikten önce yakala, sonra değil.** Geri alınabilir bir değişiklik, çalışmadan önce değişiklik öncesi durumunu bir geri alma kaydına yazar.
- **Kaldırma, Windows varsayılanını geri yazar.** Anahtarı silmek yalnızca varsayılan gerçekten yoksa doğrudur. Bilinen bir varsayılan yoksa girdiyi tahmin etmek yerine kaldırılamaz olarak işaretle.
- **İşletim sistemine göre süz.** Windows 11'e özel bir satır Windows 10'da görünmemeli.

## Testler

Değişiklikle birlikte test ekle veya güncelle. Her kaynak dosya kapsamını en üstünde adıyla sayar, testi olmayan yeni bir fonksiyon incelemeden geçmez. Bütün bir ekranı taklit etmek yerine saf fonksiyonları doğrudan test etmeyi tercih et. Birkaç koruma testi fonksiyon kaynak metnini doğrudan okur, bir tanımlayıcıyı veya var olan bir dizeyi yeniden adlandırmadan önce `tests/` içinde bakmakta fayda var.

## Pull request

Hedef `main` değil `v2-dev`. `main` yalnızca birleştirilmiş pull request'leri alır, ona yapılan bir push sürüm keser. Her pull request tek bir konu taşısın, neyin niçin değiştiğini yaz, risk etiketi veya sonuç metni oynayan bir satır varsa onu da belirt.

Sürümü etiketler belirler:

| Etiket | Etkisi |
|---|---|
| `release:major` | Ana sürümü yükseltir |
| `release:minor` | Alt sürümü yükseltir |
| `release:skip` | Sürüm çıkarmadan birleştirir |
| yok | Yama sürümü |
