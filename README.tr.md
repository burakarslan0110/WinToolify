<p align="center">
  <img src="site/assets/logo.png" alt="WinToolify logosu" width="120" />
</p>

# WinToolify

**Windows Management Harness**

WinToolify, Windows 10 ve 11'de insanların tek tek farklı kaynaklardan düzenlediği ayarları, servisleri, uygulamaları ve onarım komutlarını klavyeyle gezilen tek bir terminal ekranında toplayan kapsamlı bir PowerShell betiğidir.

[![CI](https://github.com/burakarslan0110/WinToolify/actions/workflows/ci.yml/badge.svg)](https://github.com/burakarslan0110/WinToolify/actions/workflows/ci.yml)
[![Lisans: MIT](https://img.shields.io/badge/Lisans-MIT-green.svg)](LICENSE)
![Windows 10 ve 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)
![Windows PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Diller: EN ve TR](https://img.shields.io/badge/Aray%C3%BCz-English%20%7C%20T%C3%BCrk%C3%A7e-lightgrey)

English: [README.md](README.md) · Site ve dokümanlar: [wintoolify.app](https://wintoolify.app/tr/)

<p align="center">
  <img src="site/assets/wintoolify-tour-tr-1920x1080.gif" width="900" alt="WinToolify çalışırken: Windows Servis Yönetimi ekranında iki servis sırayla işaretlenip uygulanıyor, ikisi de çalışır durumdan durdurulmuş ve devre dışına geçiyor. Gizlilik ve Telemetri ekranında üç ayar birer birer işaretlenip birlikte uygulanıyor. Son Değişikliği Geri Al ekranı da bu iki işlemi kayıt olarak tutuyor. Kayıt asistanla bitiyor: son mavi ekranın sebebi soruluyor, asistan çökme konusunu okuyor, web'de arama yapıyor, Microsoft'un o durdurma koduna ayırdığı sayfayı okuyor ve uygun raporu bir numaralı öneri olarak sunuyor." />
</p>

## Hızlı başlangıç

PowerShell'i aç ve şunu çalıştır:

```powershell
irm https://github.com/burakarslan0110/WinToolify/releases/latest/download/WinToolify.ps1 | iex
```

Bu satır son sürümü belleğe indirir ve başlatır. Yönetici değilsen WinToolify kendini yetkisi yükseltilmiş olarak yeniden başlatır, kaldığı yerden devam eder. Sen bir şey uygulayana kadar diske hiçbir şey yazılmaz.

Dosyayı elinde tutmak istersen [son sürümden](https://github.com/burakarslan0110/WinToolify/releases/latest) `WinToolify.ps1`'i indir ve şununla çalıştır:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinToolify.ps1
```

Doğrudan asistanla açmak için `-Assistant` ekle. Her sürümün yanında bir SHA-256 özeti ve imzalı bir derleme kanıtı gelir, çalıştırmadan önce indirdiğini doğrulayabilirsin:

```powershell
(Get-FileHash .\WinToolify.ps1 -Algorithm SHA256).Hash.ToLower()
gh attestation verify .\WinToolify.ps1 --repo burakarslan0110/WinToolify
```

Windows 10 veya 11, Windows PowerShell 5.1 ya da PowerShell 7, bir de yönetici hakkı gerekiyor. Betiği yetkisiz başlatırsan kendini yükseltir. winget ile yerel veya uzak bir OpenAI uyumlu sunucu isteğe bağlı, sırasıyla mağaza ve asistan için gerekiyor.

Kaynaktan derlemek başka hiçbir şey istemiyor, sadece PowerShell, modül ve internet gerekmiyor:

```powershell
.\build.cmd
```

## Gereksinimler

| | |
|---|---|
| İşletim sistemi | Windows 10 veya Windows 11 |
| PowerShell | Windows PowerShell 5.1 (PowerShell 7 de çalışır) |
| Yetki | Yönetici. Yönetici olmadan başlatırsan betik kendini yetkisi yükseltilmiş olarak yeniden başlatır. |
| İsteğe bağlı | Mağaza ve yazılım işlemleri için winget. App Installer yoksa WinToolify kurmayı teklif eder. |
| İsteğe bağlı | Asistan için yerel veya uzak, OpenAI uyumlu bir LLM sunucusu. |

## Menü haritası

```
WinToolify
│
├── Araclar ve Ayarlar
│   │
│   ├── Temel Araclar
│   │   ├── Islem Araclari ....... 51 onarim ve bakim komutu
│   │   └── Bilgi Araclari ....... 50 salt okunur rapor
│   │
│   ├── Windows Servis Yonetimi .. 43 servis, satir basina baslangic tipi
│   ├── Sistem Ayarlari .......... kalici ayarlarin sekiz bolumu
│   ├── Gizlilik Ayarlari ........ 7 ekran, 242 kayit defteri ayari
│   │   └── Uygulama Izinleri .... kamera, mikrofon, konum ve digerleri
│   ├── Gereksiz Uygulamalar ..... 122 onyuklu uygulama
│   ├── Winget Magazasi .......... 10 kategoride 252 program
│   ├── Dil Ayarlari ............. English / Turkce
│   ├── Geri Yukleme Noktasi ..... senin kararin, hicbir zaman kendiliginden
│   ├── Son Degisikligi Geri Al .. kayitli her degisiklik, en yeniden
│   └── Yapilandirma Profilleri .. ayarlarini disari aktar, baskasinda oynat
│
└── WinToolify AI Asistan ........ konsol sohbet harness'i, 7 salt okunur arac
```

## İçinde ne var

Ana menü Araçlar ve Ayarlar ile WinToolify AI Asistan olarak ikiye ayrılıyor. Araçlar ve Ayarlar onarım ve tanı komutlarını, satır başına başlangıç tipi seçilen 43 Windows servisini, Windows sürümüne göre süzülen 242 gizlilik ve sistem ayarını, tek tek kaldırılabilen 122 önyüklü uygulamayı, kategoriye göre sıralanmış 252 programlık winget destekli bir mağazayı kapsıyor. Geri yükleme noktasını sen alırsın, WinToolify onu hiçbir zaman kendiliğinden almaz. Geri alınabilir her değişiklik bir listeye düşer ve istediğin an tersine çevrilebilir. Bir bölümün uygulanmış hâli de bir profile aktarılıp başka bir makinede tekrar oynatılabilir.

Asistan, OpenAI uyumlu her uç noktayla konuşan bir konsol sohbet kabuğudur, yerel veya uzak fark etmez. Araçlarının hepsi salt okunur: WinToolify'ın kendi kataloğunda arar, makine hakkında okur, webde arar, kendine kısa bir not düşer, başka bir şey yapmaz. Hiçbir şeyi kendisi uygulamaz. Bir çözüm önermek istediğinde numaralı bir kart basar, sen numarayı yazınca menüden bulmuş gibi aynı onay ve aynı geri alma kaydı devreye girer.

## Arayüz nasıl çalışır

Her ekran aynı listedir. Ok tuşları gezinir, `Enter` açar veya çalıştırır, `Esc` geri döner. Windows'u değiştiren ekranlar iki adımda ilerler. `Space` bir satırı işaretler, `Enter` işaretlenen her şeyi uygular, yani menüde gezinmekle hiçbir şey uygulanmaz. Her satır bir risk etiketi taşır. `SAFE` uyarı istemez, `CAUTION` neyin değişeceğini söyler, `ADVANCED` sonucu açık açık yazar ve onaylamak için bir kelime yazmanı ister.

## Depo yapısı

Kaynaklar `src/` altında numaralı katmanlara bölünmüş ve bu sırayla birleştiriliyor, yani bir çağrı her zaman aşağıyı gösteriyor, yukarıyı asla:

```
src/
  00-core/       depolama, kayit defteri, hatalar, yetki yukseltme, geri yukleme
  10-i18n/       Ingilizce ve Turkce metinler
  20-tui/        konsol, cerceveler, listeler, paneller, REPL
  30-engine/     uygulama kayitlari, islem plani, korumali degisiklik, geri alma
  40-catalogs/   veri: servisler, paketler, gizlilik satirlari, DNS, magaza, araclar
  50-apply/      her katalog icin bir uygulayici
  60-actions/    Islem Araclari komutlari, asistan istemcisi ve ajani
  70-info/       salt okunur raporlar
  80-screens/    her ekran icin bir dosya
  90-main/       yetki yukseltme ve giris noktasi
tests/           Pester testleri, her alan icin bir dosya
tools/           derleyici ve denetim calistiricisi
```

`dist/WinToolify.ps1` derlemenin ürünüdür, depoda durmaz.

## Derleme ve test

```powershell
.\tools\Invoke-WtChecks.ps1
```

Tek kapı bu. CI de tam olarak bunu çalıştırır: derler, ayrıştırır, PowerShell 5.1 ve 7.0 uyumluluğunu denetler, sonra tüm Pester paketini koşturur, 3.000'e yakın test. `Invoke-Pester`'ı kendin çağırma, testler derlenmiş dosyaya karşı yazıldı, kaynaklara karşı değil.

## Katkı

Issue ve pull request'ler açık. [CONTRIBUTING.md](CONTRIBUTING.md) dosyasında kurulum adımları ve derlemeyle testlerin gerçekten dayattığı kurallar var.

## Güvenlik bildirimi

WinToolify yükseltilmiş yetkiyle çalışır ve sistem durumunu değiştirir. Güvenlik açığı gibi görünen bir şeyi herkese açık bir issue yerine lütfen özel olarak bildir. Bildirim yolu ve kapsam [SECURITY.md](SECURITY.md) dosyasında.

## Lisans

[MIT](LICENSE). Telif hakkı (c) 2025-2026 Burak Arslan.
