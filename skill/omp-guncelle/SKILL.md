---
name: omp-guncelle
description: omp'yi güncellemek ("omp'yi güncelle", "omp güncellermisin", "omp update"), omp sürümünü kontrol etmek, omp'yi geri almak ya da omp yamaları (omp-yamalari) hakkındaki sorular için kullan.
---

# omp-guncelle

Bu omp, KadirBerkpolat1'in yamalarıyla git kaynağından çalışır (`~/.local/share/omp-yamalari`). Kurulum, güncelleme ve geri alma yalnız `omp-yama` ile yapılır:

```sh
~/.local/share/omp-yamalari/repo/omp-yama <komut>
```

## Asla

- `omp update`, @oh-my-pi paketleri için `bun install -g` / `bun update -g`, `npm i -g` ya da omp.sh kurulum betiği çalıştırma: hepsi yamasız bir omp kurar.
- `~/.local/share/omp-yamalari` altındaki dosyaları elle düzenleme, yama çakışmasını elle çözme. Yamalar yalnız GitHub'daki KadirBerkpolat1/omp-yamalari deposundan gelir.

## Güncelleme

1. `~/.local/share/omp-yamalari/repo/omp-yama guncelle` çalıştır. Bash aracına `timeout: 3600` ver: birkaç dakika sürer (ilk seferde daha uzun); bitene kadar bekle, yarıda kesme ya da ikinci kez başlatma.
2. Çıktının sonundaki satırları oku ve kullanıcıya Türkçe özetle:
   - `SONUC`: `guncellendi`, `guncel` (zaten son sürüm) ya da `basarisiz`.
   - `ESKI` → `YENI`: `<sürüm> <commit> <kip>`.
   - `KIP=en-yeni`: upstream'in en yeni kararlı sürümü + yamalar. `KIP=test-edilmis`: yayınlayanın test ettiği sürüm.
   - `UPSTREAM`: temel alınan upstream sürümü (`vX.Y.Z` etiketi ya da `taban:<commit>`).
   - `NEDEN`: en yeni sürüm neden kullanılmadı (ör. `cakisma`, `native-farki`, `npm-yok`, `dogrulama`, `geri-alindi`) ya da hatanın nedeni; `-` ise yok. `SONUC=guncel` ile dolu bir `NEDEN`: en yeni sürüm yamalarla kullanılamadı ya da daha önce geri alınan/reddedilen bir sürüm atlandı; yeniden denemek sonucu değiştirmez, yeni yayını bekle.
   - `UYARI=` satırlarını aynen ilet.
3. `SONUC=guncellendi` ise yeni sürümü bir kez dene: `omp -p --no-session --no-tools "Reply with exactly: OK"`. Sonra kullanıcıya omp'yi kapatıp yeniden açmasını söyle: açık oturum eski sürümle çalışmaya devam eder.

## Başarısız olursa

`SONUC=basarisiz` ise hiçbir şey değişmedi, omp eskisi gibi çalışır. `NEDEN`'i ve gerekirse `GUNLUK` dosyasının son satırlarını oku, kullanıcıya kısaca anlat. Testte ya da doğrulamada kalan sürüm kaydedilir ve kendiliğinden yeniden denenmez; sorun giderildiyse `omp-yama guncelle --test-edilmis` yeniden dener. Bilinen durumlar:

- glibc eski ("glibc ... istiyor"): kullanıcı `sudo pacman -Syu` ile sistemi güncellesin, sonra yeniden dene.
- bun eski: `~/.bun/bin/bun` ise `omp-yama` kendisi yükseltir; değilse bun'ı kuran paket yöneticisiyle güncellesin ya da `curl -fsSL https://bun.sh/install | bash`.
- İşlemci x86-64-v3 (AVX2) desteklemiyor: test edilmiş sürümün native'i çalışmaz; yayınlayana (KadirBerkpolat1) bildir.
- Ağ hatası ("çekilemedi", "indirilemedi"): bağlantıyı denetleyip yeniden dene.
- "başka bir omp-yama işlemi sürüyor" (çıkış kodu 3): diğer işlemin bitmesini bekle, sonra yeniden dene.
- "yetersiz disk alanı": en az 3 GB boş yer açılsın.
- "yayın bozuk": yayınlayana bildir; elle düzeltmeye çalışma.
- PATH uyarısı (`UYARI=`): satırdaki bash/fish komutunu kullanıcıya ilet; yeni terminalde `omp --version` ile denetlesin.

## Diğer komutlar

- `omp-yama kontrol`: canlı sürümü (`CANLI`), son yayını (`SON_YAYIN`), upstream'in son kararlı sürümünü (`UPSTREAM_SON`) ve bir daha kendiliğinden kurulmayacak (geri alınan ya da doğrulamada kalan) sürüm sayısını (`REDDEDILEN`) gösterir; hiçbir şeyi değiştirmez. Sürüm soruları için bunu kullan. `DURUM`:
  - `guncelleme-var`: yeni bir yayın var; güncellemeyi öner. Canlı sürüm geri alınarak seçildiyse `guncelle` geri alınan sürümü kurmaz, `SONUC=guncel` diyebilir.
  - `upstream-yeni`: yayın aynı ama upstream'in daha yeni bir kararlı sürümü var. `guncelle` onu yamalarla dener; çakışma ya da test hatasında test edilmiş sürümde kalır. Kullanıcıya bunu söyleyerek öner.
  - `guncel`: yapılacak bir şey yok.
- `omp-yama geri-al`: yeni sürüm, omp yeniden açıldıktan sonra sorun çıkarırsa önceki sürüme anında döner; sonra omp'yi yeniden açtır. Geri alınan sürüm kaydedilir: düz `guncelle` onu bir daha kurmaz, yeni yayını ya da yeni upstream sürümünü bekler. Kullanıcı test edilmiş sürümü yine de geri isterse `omp-yama guncelle --test-edilmis`.
- `omp-yama guncelle --test-edilmis`: upstream'in en yeni sürümünü denemeden yayınlayanın test ettiği sürüme geçer; o sürüm daha önce geri alınmış ya da doğrulamada kalmış olsa da yeniden dener ve kaydını siler.
- `omp-yama kaldir`: yalnız kullanıcı açıkça onaylarsa. Yamalı omp'yi kaldırır, önceki `omp` komutunu ve bu skill'in yerindekini geri koyar, `~/.local/share/omp-yamalari`'yı siler.

## Yamalar

Yamaların listesi ve nasıl çalıştığı: https://github.com/KadirBerkpolat1/omp-yamalari (README). Yerel kopya: `~/.local/share/omp-yamalari/repo/README.md`.
