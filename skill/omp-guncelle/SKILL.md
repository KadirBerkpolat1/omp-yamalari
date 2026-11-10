---
name: omp-guncelle
description: omp'yi güncellemek ("omp'yi güncelle", "omp güncellermisin", "omp update"), omp sürümünü kontrol etmek, omp'yi geri almak ya da omp yamaları (omp-yamalari) hakkındaki sorular için kullan.
---

# omp-guncelle

Bu omp, KadirBerkpolat1'in yamalarıyla git kaynağından çalışır (`~/.local/share/omp-yamalari`). Kurulum, güncelleme ve geri alma yalnız `omp-yama` ile yapılır. `omp-yama` PATH'te değildir; her zaman tam yoluyla çalıştır:

```sh
~/.local/share/omp-yamalari/repo/omp-yama <komut>
```

## Asla

- `omp update`, @oh-my-pi paketleri için `bun install -g` / `bun update -g`, `npm i -g` ya da omp.sh kurulum betiği çalıştırma: hepsi yamasız bir omp kurar.
- `~/.local/share/omp-yamalari` altındaki dosyaları elle düzenleme, yama çakışmasını elle çözme. Yamalar yalnız GitHub'daki KadirBerkpolat1/omp-yamalari deposundan gelir.

## Güncelleme

1. `~/.local/share/omp-yamalari/repo/omp-yama guncelle` çalıştır, bash aracına `timeout: 3600` ver. Birkaç dakika sürer (ilk seferde daha uzun). omp 60 saniyeyi geçen komutu arka plana alır: iş sürer, sonucu bitince konuşmaya kendiliğinden gelir. Kullanıcıya sonuç gelene kadar omp'yi açık tutmasını söyle (omp kapanırsa iş yarıda kesilir) ve sonucu bekle; ikinci bir `omp-yama` başlatma.
2. Çıktının sonundaki satırları oku ve kullanıcıya Türkçe özetle:
   - `SONUC`: `guncellendi`, `guncel` (değişiklik yok) ya da `basarisiz`.
   - `ESKI` → `YENI`: `<sürüm> <commit> <kip>`.
   - `KIP=en-yeni`: upstream'in en yeni kararlı sürümü + yamalar. `KIP=test-edilmis`: yayınlayanın test ettiği sürüm.
   - `UPSTREAM`: temel alınan upstream sürümü (`vX.Y.Z` etiketi ya da `taban:<commit>`).
   - `NEDEN`: en yeni sürümün neden kullanılmadığı ya da hatanın nedeni; `-` ise yok. `… zaten test edilmiş sürümün tabanında` hata değildir: upstream'in en yeni sürümü zaten içeride. `etiket-yok`, `npm-yok` ve `denenemedi` ağdan kaynaklanabilir; sonraki çalıştırma yeniden dener. `cakisma` ve `native-farki` yeni yayına kadar sürer. `dogrulama` (testte kaldı) ve `geri-alindi` kaydedilir; o aday bir daha denenmez. En yeni sürümdeyken yeni aday kullanılamazsa daha eski test edilmiş sürüme dönülmez, `SONUC=guncel` olur.
   - `UYARI=` satırlarını aynen ilet (ör. PATH komutları, bun yükseltmesi).
3. `SONUC=guncellendi` ise yeni sürümü bir kez dene: `~/.local/share/omp-yamalari/bin/omp -p --no-session --no-tools "Reply with exactly: OK"`. Kimlik doğrulama ya da ağ hatası verirse bu, sürümün sorunu değildir; `geri-al` için gerekçe sayma (geri alınan sürüm bir daha kurulmaz). Sonra kullanıcıya omp'yi kapatıp yeniden açmasını söyle: açık oturum eski sürümle çalışmaya devam eder.

## Başarısız olursa

`SONUC=basarisiz` ise hiçbir şey değişmedi, omp eskisi gibi çalışır. `NEDEN`'i ve gerekirse `GUNLUK` dosyasının son satırlarını oku, kullanıcıya kısaca anlat. Testte kalan sürüm kaydedilir ve kendiliğinden yeniden denenmez; sorun giderildiyse `~/.local/share/omp-yamalari/repo/omp-yama guncelle --test-edilmis` test edilmiş sürümü yeniden dener. Bilinen durumlar:

- glibc eski ("glibc ... istiyor"): kullanıcı `sudo pacman -Syu` ile sistemi güncellesin, sonra yeniden dene.
- bun eski: `~/.bun/bin/bun` ise `omp-yama` kendisi yükseltir; değilse bun'ı kuran paket yöneticisiyle güncellesin ya da `curl -fsSL https://bun.sh/install | bash`.
- İşlemci x86-64-v3 (AVX2) desteklemiyor: test edilmiş sürümün native'i çalışmaz; yayınlayana (KadirBerkpolat1) bildir.
- Ağ hatası ("çekilemedi", "indirilemedi"): bağlantıyı denetleyip yeniden dene.
- "başka bir omp-yama işlemi sürüyor" (çıkış kodu 3): önceki iş sürüyor; sonucunu bekle, gerekirse sonra yeniden dene.
- "yetersiz disk alanı": en az 3 GB boş yer açılsın.
- "yayın bozuk": yayınlayana bildir; elle düzeltmeye çalışma.
- PATH uyarısı (`UYARI=`): kullanıcının kabuğuna (bash, zsh, fish) uyan komutu ilet; yeni terminalde `omp --version` ile denetlesin.

## Diğer komutlar

Hepsi `~/.local/share/omp-yamalari/repo/omp-yama <komut>` biçiminde çalışır:

- `kontrol`: canlı sürümü (`CANLI`), son yayını (`SON_YAYIN`), upstream'in son kararlı sürümünü (`UPSTREAM_SON`) ve bir daha kendiliğinden kurulmayacak (geri alınan ya da testte kalan) sürüm sayısını (`REDDEDILEN`) gösterir; hiçbir şeyi değiştirmez. Sürüm soruları için bunu kullan. `DURUM`:
  - `guncelleme-var`: yeni bir yayın var; güncellemeyi öner. Canlı sürüm geri alınarak seçildiyse `guncelle` geri alınan sürümü kurmaz, `SONUC=guncel` diyebilir.
  - `upstream-yeni`: yayın aynı ama upstream'in daha yeni bir kararlı sürümü var. `guncelle` onu yamalarla dener; çakışma ya da test hatasında yeni bir şey kurulmaz ya da test edilmiş sürüme geçilir. Kullanıcıya bunu söyleyerek öner.
  - `guncel`: yapılacak bir şey yok.
- `geri-al`: yeni sürüm, omp yeniden açıldıktan sonra sorun çıkarırsa önceki sürüme anında döner; sonra omp'yi yeniden açtır. Geri alınan sürüm kaydedilir: düz `guncelle` onu bir daha kurmaz, yeni yayını ya da yeni upstream sürümünü bekler.
- `guncelle --test-edilmis`: upstream'in en yeni sürümünü denemeden yayınlayanın test ettiği sürüme geçer; o sürüm daha önce geri alınmış ya da testte kalmış olsa da yeniden dener ve kaydını siler. Yalnız test edilmiş sürüm içindir; kaydedilmiş bir en-yeni sürümü geri getirmez.
- `kaldir`: yalnız kullanıcı açıkça onaylarsa. Yamalı omp'yi kaldırır, önceki `omp` komutunu ve bu skill'in yerindekini geri koyar, `~/.local/share/omp-yamalari`'yı siler. Açık oturumun kullandığı dosyalar da silinir: bitince kullanıcıya omp'yi hemen kapatmasını söyle (yeniden açınca önceki omp çalışır).

## Yamalar

Yamaların listesi ve nasıl çalıştığı: https://github.com/KadirBerkpolat1/omp-yamalari (README). Yerel kopya: `~/.local/share/omp-yamalari/repo/README.md`.
