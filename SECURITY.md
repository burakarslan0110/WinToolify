# Security Policy

WinToolify runs as an administrator, rewrites registry keys, changes service start types, touches the hosts file and the firewall, and can be launched from an `irm | iex` one-liner. A bug anywhere in that path deserves a proper report.

Türkçe için [aşağıya](#güvenlik-politikası) bak.

## Supported versions

Only the latest release is supported. Fixes ship in the next release rather than as a patch to an older tag, so update first if you're behind.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Use GitHub's private vulnerability reporting instead: go to the [Security tab](https://github.com/burakarslan0110/WinToolify/security) and choose **Report a vulnerability**. It stays between you and the maintainer until a fix is out.

Include what you can: what an attacker gains and what access they need to start, exact reproduction steps and the Windows build you saw it on, the affected file and function if you found it, and the release or commit you tested. Expect a first reply within a week. A confirmed report gets a fix and a release, and you're credited in the release notes unless you'd rather not be.

## Scope

In scope:

- Privilege escalation beyond the administrator rights the tool already asks for
- Command, script, or argument injection through anything the tool accepts, including search boxes, paths, profile files, undo records, and assistant output
- A downloaded artifact accepted without its size or hash being checked
- An undo record that fails to restore, or restores the wrong state
- Data leaving the machine that the assistant's consent panel doesn't disclose, or masking that fails to mask
- Anything letting a non-administrator user influence what the elevated process does

Out of scope:

- Windows behaving as documented once a setting is applied, since the consequence text on each row is the contract
- Anything that needs administrator rights the attacker already has, since WinToolify runs elevated by design
- The Visual C++ redistributable installers, unmodified Microsoft binaries
- A third-party LLM endpoint you pointed the assistant at yourself
- Reports from an automated scanner with no working reproduction

---

# Güvenlik Politikası

WinToolify yönetici olarak çalışır, kayıt defteri anahtarlarını yeniden yazar, servis başlangıç tiplerini değiştirir, hosts dosyasına ve güvenlik duvarına dokunur, bir `irm | iex` tek satırıyla başlatılabilir. Bu yolların herhangi birindeki bir hata düzgün bir bildirimi hak eder.

İngilizcesi için [yukarıya](#security-policy) bak.

## Desteklenen sürümler

Sadece son sürüm destekleniyor. Düzeltmeler eski bir etikete yama olarak değil bir sonraki sürümle geliyor, gerideysen önce güncelle.

## Açık bildirimi

Güvenlik sorunu için lütfen herkese açık bir issue açma. Bunun yerine GitHub'ın özel açık bildirimini kullan. Deponun [Security sekmesine](https://github.com/burakarslan0110/WinToolify/security) git, **Report a vulnerability** seçeneğini seç. Bildirim, düzeltme çıkana kadar seninle bakımcı arasında kalır.

Elinden geldiğince şunları ekle: saldırganın ne kazandığı ve başlamak için hangi erişime ihtiyacı olduğu, tam yeniden üretme adımları ve gördüğün Windows yapısı, bulduysan etkilenen dosya ve fonksiyon, test ettiğin sürüm veya commit. Bir hafta içinde ilk cevabı bekleyebilirsin. Doğrulanan bir bildirim bir düzeltme ve bir sürümle sonuçlanır, aksini istemediğin sürece sürüm notlarında adın geçer.

## Kapsam

Kapsam içinde:

- Aracın zaten istediği yönetici yetkisinin ötesine geçen yetki yükseltme
- Aracın kabul ettiği herhangi bir girdiden, arama kutuları, yollar, profil dosyaları, geri alma kayıtları ve asistan çıktısı dahil, komut, betik veya argüman enjeksiyonu
- İndirilen bir dosyanın boyutu veya özeti denetlenmeden kabul edilmesi
- Geri yüklemeyi başaramayan veya yanlış durumu geri yükleyen bir geri alma kaydı
- Asistanın onay panelinin açıklamadığı bir verinin makineden çıkması veya maskelemenin maskeleyememesi
- Yönetici olmayan bir kullanıcının yükseltilmiş sürecin ne yaptığını etkilemesine izin veren her şey

Kapsam dışında:

- Bir ayar uygulandıktan sonra Windows'un belgelendiği gibi davranması, çünkü her satırdaki sonuç metni buradaki sözleşmedir
- Saldırganın zaten sahip olduğu yönetici yetkisini gerektiren her şey, çünkü WinToolify tasarımı gereği yükseltilmiş çalışır
- Değiştirilmeden yeniden dağıtılan Microsoft ikilileri olan Visual C++ kurucuları
- Asistanı kendi yönlendirdiğin üçüncü taraf bir LLM uç noktası
- Yalnızca otomatik bir tarayıcının ürettiği, çalışan bir yeniden üretimi olmayan bildirimler
