#!/usr/bin/env bash
# yayinla.sh: yayınlayanın canlı omp dalından (OMP_KAYNAK) yamalar.patch, yama.env ve README'deki
# yamalar bloğunu üretir, native'i hazırlar ve yayını GitHub'a gönderir.
#
#   ./yayinla.sh          üretir ve denetler; native gerekiyorsa Releases'a yükler, commit edip push eder
#   ./yayinla.sh --kuru   üretir ve denetler, native gerekiyorsa önbelleğe derler; commit, push ve Releases yok
#
# Ortam: OMP_KAYNAK (varsayılan ~/Projeler/oh-my-pi). Önbellek: ${XDG_CACHE_HOME:-~/.cache}/omp-yamalari.
# shellcheck disable=SC2016 # tek tırnaklı JS ve Markdown metinleri bilerek genişletilmez
set -Eeuo pipefail
shopt -s inherit_errexit

beklenmeyen_hata() {
	local kod=$?
	printf 'yayinla: HATA: beklenmeyen hata (satır %s, çıkış %s): %s\n' "$1" "$kod" "$BASH_COMMAND" >&2
}
trap 'beklenmeyen_hata "$LINENO"' ERR

REPO=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=ortak.sh
source "$REPO/ortak.sh"

OMP_KAYNAK=${OMP_KAYNAK:-$HOME/Projeler/oh-my-pi}
ONBELLEK=${XDG_CACHE_HOME:-$HOME/.cache}/omp-yamalari
BUN=$(command -v bun || printf '%s\n' "$HOME/.bun/bin/bun")
NATIVE_VARLIK=$NATIVE_MODERN.zst
# Yayına girecek satırlarda (yamada eklenenler ve dosya başlıkları, README'nin yamalar bloğu) bunlardan biri
# geçerse yayın durur: ev dizini yolları, token ve anahtar biçimleri. Yayınlanmaması gereken kişisel desenler
# (sunucu adresleri gibi) repoya değil GIZLI_DESEN_DOSYASI'na yazılır: satır başına bir ERE, `#` ile başlayan
# satırlar yorum. Yanlış alarm veren bir satır IZINLI_SATIR_DOSYASI'na olduğu gibi (yamada baştaki + olmadan)
# yazılırsa bildirilmez; orada da `#` ile başlayan satırlar yorumdur.
GIZLI_DESENLER=(
	'/home/[^/[:space:]]+'
	'/Users/'
	'gh[pousr]_[A-Za-z0-9_]{20,}'
	'github_pat_'
	'(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}'
	'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
	'AIza[0-9A-Za-z_-]{30,}'
	'BEGIN [A-Z ]*PRIVATE KEY'
)
GIZLI_DESEN_DOSYASI=${XDG_CONFIG_HOME:-$HOME/.config}/omp-yamalari/gizli-desenler
IZINLI_SATIR_DOSYASI=${XDG_CONFIG_HOME:-$HOME/.config}/omp-yamalari/izinli-satirlar
# git status'un isteğe bağlı index tazelemesi canlı omp deposunun index'ine yazmasın.
export GIT_OPTIONAL_LOCKS=0

KURU=0
GH_VAR=1
GECICI=
DERLEME_DIZINI=
YENI_NATIVE=
NATIVE_KAYNAK='' NATIVE_URL='' NATIVE_SHA256='' NATIVE_GLIBC='' NATIVE_NPM_SURUM='' NATIVE_NPM_INTEGRITY=''
NATIVE_YOLU=
RELEASE_GEREK=0

bilgi() { printf 'yayinla: %s\n' "$*" >&2; }

hata() {
	printf 'yayinla: HATA: %s\n' "$*" >&2
	exit 1
}

kullanim() {
	printf 'Kullanım: %s [--kuru]\n' "${0##*/}"
	printf '  --kuru  her şeyi üretir ve denetler; commit, push ve GitHub Releases yapmaz\n'
}

utc_simdi() { date -u +%Y-%m-%dT%H:%M:%SZ; }

boyut() { numfmt --to=iec-i --suffix=B "$(stat -c %s -- "$1")"; }

# worktree_kaldir <derleme-dizini>: dizindeki omp worktree'sini, yarım kalmış ya da kilitli olsa da, omp
# deposundaki kaydıyla birlikte siler. Worktree olarak tanınmayan bir dizinin kaydı ancak dizin silinince kalkar.
worktree_kaldir() {
	git -C "$OMP_KAYNAK" worktree remove -f -f "$1/omp" >/dev/null 2>&1 || true
	if [[ -e $1/omp ]]; then
		rm -rf -- "$1/omp"
		git -C "$OMP_KAYNAK" worktree remove -f -f "$1/omp" >/dev/null 2>&1 || true
	fi
	rm -rf -- "$1"
}

derleme_kaldir() {
	[[ -n $DERLEME_DIZINI ]] || return 0
	worktree_kaldir "$DERLEME_DIZINI"
	DERLEME_DIZINI=
}

# artiklari_temizle: öldürülmüş bir önceki çalışmanın bıraktığı derleme worktree'lerini (dizini silinmiş olsa da
# kaydıyla) ve yarım native dizinlerini siler. Omp deposunun başka worktree'lerine dokunmamak için
# `git worktree prune` kullanılmaz: o, takılı olmayan bir diskteki worktree'nin kaydını da silerdi.
artiklari_temizle() {
	local satir d
	while IFS= read -r -d '' satir; do
		[[ $satir == "worktree $ONBELLEK/derleme."*/omp ]] || continue
		d=${satir#worktree }
		worktree_kaldir "${d%/omp}"
	done < <(git -C "$OMP_KAYNAK" worktree list --porcelain -z 2>/dev/null)
	for d in "$ONBELLEK"/derleme.*/ "$ONBELLEK"/native/.yeni.*/; do
		[[ ! -d $d ]] || rm -rf -- "$d"
	done
}

temizle() {
	trap '' INT TERM HUP
	derleme_kaldir
	[[ -z $YENI_NATIVE ]] || rm -rf -- "$YENI_NATIVE"
	[[ -z $GECICI ]] || rm -rf -- "$GECICI"
}

izinli_mi() {
	case $1 in
	omp-yama | ortak.sh | yayinla.sh | README.md | yama.env | yamalar.patch | .gitignore | LICENSE | skill/*) return 0 ;;
	esac
	return 1
}

# repo_dosyalarini_denetle: repoda yalnız yayına ait dosyalar değişmiş olmalı; `git add -A` hepsini commit eder.
repo_dosyalarini_denetle() {
	local kayit eski
	local -a yabanci=()
	git -C "$REPO" status --porcelain=v1 -z --untracked-files=all >"$GECICI/repo-durumu"
	while IFS= read -r -d '' kayit; do
		izinli_mi "${kayit:3}" || yabanci+=("$kayit")
		if [[ ${kayit:0:2} == *[RC]* ]]; then
			IFS= read -r -d '' eski || true
			izinli_mi "$eski" || yabanci+=("${kayit:0:2} $eski")
		fi
	done <"$GECICI/repo-durumu"
	if ((${#yabanci[@]})); then
		printf '  %s\n' "${yabanci[@]}" >&2
		hata "$REPO içinde yayına ait olmayan değişiklikler var (yukarıda); taşı, sil ya da ayrıca commit et"
	fi
}

# repo_denetle: push öncesi repoda yalnız yayına ait dosyalar değişmiş olmalı; main dalı, omp-yamalari'yı
# gösteren origin ve gh oturumu gerekir.
repo_denetle() {
	local url
	repo_dosyalarini_denetle
	[[ $(git -C "$REPO" symbolic-ref -q --short HEAD || true) == main ]] || hata "$REPO main dalında değil"
	url=$(git -C "$REPO" remote get-url origin 2>/dev/null) || hata "$REPO içinde origin remote'u yok"
	[[ ${url%.git} == *github.com[:/]"$OMP_YAMALARI_GH" ]] || hata "origin ($url) $OMP_YAMALARI_GH deposunu göstermiyor"
	gh auth status >/dev/null 2>&1 9>&- || hata "gh oturumu açık değil (gh auth login)"
}

onceki() { manifest_oku "$ONCEKI" "$1"; }

# ayni_yayin: önceki yayınla TABAN, AGAC ve bütün native alanları aynı mı (aynıysa YAYIN_ZAMANI korunur ki
# arkadaşların hesapladığı test edilmiş commit değişmesin).
ayni_yayin() {
	local k
	for k in TABAN AGAC NATIVE_ANAHTAR NATIVE_KAYNAK NATIVE_URL NATIVE_SHA256 NATIVE_GLIBC NATIVE_NPM_SURUM NATIVE_NPM_INTEGRITY; do
		[[ $(onceki "$k") == "${!k}" ]] || return 1
	done
}

manifest_yaz() {
	local k
	printf '# omp-yamalari yayını; yayinla.sh yazar, elle düzenleme.\n'
	for k in YAYIN_ZAMANI SURUM TABAN AGAC YAMALI_COMMIT NATIVE_ANAHTAR NATIVE_KAYNAK NATIVE_URL NATIVE_SHA256 NATIVE_GLIBC \
		NATIVE_NPM_SURUM NATIVE_NPM_INTEGRITY; do
		[[ -z ${!k} ]] || printf '%s=%s\n' "$k" "${!k}"
	done
}

native_npm() {
	NATIVE_KAYNAK=npm
	NATIVE_NPM_SURUM=$1
	# shellcheck disable=SC2034 # manifest_yaz ve ayni_yayin ${!k} ile okur
	NATIVE_NPM_INTEGRITY=$2
}

native_release() {
	NATIVE_KAYNAK=release
	NATIVE_URL=https://github.com/$OMP_YAMALARI_GH/releases/download/$RELEASE_ETIKETI/$NATIVE_VARLIK
	NATIVE_SHA256=$1
	NATIVE_GLIBC=$2
}

# release_oku: RELEASE_ETIKETI yayımlanmış ve native dosyası yüklenmişse notlarındaki NATIVE_SHA256 ve
# NATIVE_GLIBC'yi R_SHA256/R_GLIBC'ye okur. Release yoksa 1 döner; GitHub'a ulaşılamazsa durur.
release_oku() {
	local notlar=$GECICI/release-notlari
	R_SHA256='' R_GLIBC=''
	((GH_VAR)) || return 1
	if ! gh api "repos/$OMP_YAMALARI_GH/releases/tags/$RELEASE_ETIKETI" >"$GECICI/release.json" 2>"$GECICI/release.err" 9>&-; then
		grep -q 'HTTP 404' "$GECICI/release.err" && return 1
		hata "GitHub Releases sorgulanamadı: $(tr '\n' ' ' <"$GECICI/release.err")"
	fi
	VARLIK=$NATIVE_VARLIK "$BUN" -e '
		const r = await Bun.file(process.argv[1]).json();
		const yuklu = (r.assets ?? []).some(a => a.name === process.env.VARLIK && a.state === "uploaded");
		console.log(`${String(r.body ?? "").replaceAll("\r", "")}\nVARLIK_VAR=${yuklu ? 1 : 0}`);' \
		"$GECICI/release.json" >"$notlar" || hata "GitHub Releases yanıtı okunamadı"
	[[ $(manifest_oku "$notlar" VARLIK_VAR) == 1 ]] ||
		hata "$RELEASE_ETIKETI release'inde $NATIVE_VARLIK yok; release'i sil (gh release delete $RELEASE_ETIKETI --repo $OMP_YAMALARI_GH) ve yeniden çalıştır"
	[[ $(manifest_oku "$notlar" NATIVE_ANAHTAR) == "$NATIVE_ANAHTAR" ]] ||
		hata "$RELEASE_ETIKETI notlarındaki NATIVE_ANAHTAR bu yayının native anahtarı değil"
	R_SHA256=$(manifest_oku "$notlar" NATIVE_SHA256)
	R_GLIBC=$(manifest_oku "$notlar" NATIVE_GLIBC)
	[[ $R_SHA256 =~ ^[0-9a-f]{64}$ && $R_GLIBC =~ ^[0-9]+\.[0-9]+$ ]] ||
		hata "$RELEASE_ETIKETI notlarından NATIVE_SHA256/NATIVE_GLIBC okunamadı"
}

# npm_native_sorgula <sürüm>: npm'deki native paketinin tarball adresini ve integrity'sini NPM_TARBALL ile
# NPM_INTEGRITY'ye okur; sürüm npm'de yoksa (HTTP 404) 1 döner. Registry'ye ulaşılamaz ya da başka bir yanıt
# (429, 5xx) gelirse yayını durdurur: geçici bir ağ hatası yayınlanan native'i sessizce değiştirmemeli.
# $(...) gibi bir alt kabukta çağrılmamalı; hata ancak ana kabukta bütün betiği durdurur.
npm_native_sorgula() {
	local yanit=$GECICI/npm.json kod dist
	NPM_TARBALL='' NPM_INTEGRITY=''
	kod=$(curl -sSL -o "$yanit" -w '%{http_code}' "https://registry.npmjs.org/$NPM_NATIVE_PAKETI/$1" 9>&-) ||
		hata "npm registry'ye ulaşılamadı ($NPM_NATIVE_PAKETI@$1)"
	case $kod in
	200) ;;
	404) return 1 ;;
	*) hata "npm registry $NPM_NATIVE_PAKETI@$1 için HTTP $kod döndü" ;;
	esac
	dist=$("$BUN" -e '
		const d = (await Bun.file(process.argv[1]).json()).dist ?? {};
		console.log(`${d.tarball ?? ""} ${d.integrity ?? ""}`);' "$yanit") ||
		hata "npm registry yanıtı okunamadı ($NPM_NATIVE_PAKETI@$1)"
	NPM_TARBALL=${dist%% *}
	NPM_INTEGRITY=${dist#* }
	[[ $NPM_TARBALL =~ ^https://[^[:space:]]+$ && $NPM_INTEGRITY =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] ||
		hata "npm registry yanıtında $NPM_NATIVE_PAKETI@$1 için tarball adresi ya da sha512 integrity yok"
}

# native_onceki: (a) son commit edilmiş yayın aynı native anahtarını kullanıyorsa ve o native hâlâ
# indirilebiliyorsa native alanları aynen korunur.
native_onceki() {
	local s i
	[[ $(onceki NATIVE_ANAHTAR) == "$NATIVE_ANAHTAR" ]] || return 1
	case $(onceki NATIVE_KAYNAK) in
	npm)
		s=$(onceki NATIVE_NPM_SURUM)
		i=$(onceki NATIVE_NPM_INTEGRITY)
		[[ -n $s ]] || return 1
		npm_native_sorgula "$s" || return 1
		[[ $NPM_INTEGRITY == "$i" ]] ||
			hata "npm'deki $NPM_NATIVE_PAKETI@$s integrity'si önceki yayındakinden farklı; yayımlanmış npm sürümü değişmez, elle incele"
		native_npm "$s" "$i"
		;;
	release)
		release_oku || return 1
		[[ $R_SHA256 == "$(onceki NATIVE_SHA256)" && $R_GLIBC == "$(onceki NATIVE_GLIBC)" ]] || return 1
		native_release "$R_SHA256" "$R_GLIBC"
		;;
	*) return 1 ;;
	esac
}

# native_npm_ara: (b) son 10 kararlı upstream sürümünden native anahtarı aynı olan en yenisinin npm'deki native'i.
native_npm_ara() {
	local t c k
	for t in "${SON_ETIKETLER[@]}"; do
		c=$(git -C "$OMP_KAYNAK" rev-parse -q --verify "refs/tags/$t^{commit}") || hata "upstream etiketi $t yerelde yok"
		k=$(native_anahtar "$GITDIR" "$c" 9>&-) || hata "$t için native anahtarı hesaplanamadı"
		[[ $k == "$NATIVE_ANAHTAR" ]] || continue
		npm_native_sorgula "${t#v}" || continue
		native_npm "${t#v}" "$NPM_INTEGRITY"
		return 0
	done
	return 1
}

# native_release_var: (c) bu anahtarın native'i GitHub Releases'ta zaten yüklü.
native_release_var() {
	release_oku || return 1
	native_release "$R_SHA256" "$R_GLIBC"
}

# onbellek_tamam: önbellekte bu anahtarın eksiksiz ve kendi içinde tutarlı bir derlemesi var mı.
onbellek_tamam() {
	local d=$NATIVE_DIZINI sha
	[[ -f $d/$NATIVE_MODERN && -f $d/$NATIVE_VARLIK && -f $d/bilgi ]] || return 1
	[[ $(manifest_oku "$d/bilgi" NATIVE_ANAHTAR) == "$NATIVE_ANAHTAR" && -n $(manifest_oku "$d/bilgi" NATIVE_GLIBC) ]] || return 1
	sha=$(manifest_oku "$d/bilgi" NATIVE_SHA256)
	[[ $sha =~ ^[0-9a-f]{64}$ && $(sha256sum <"$d/$NATIVE_MODERN") == "$sha  -" ]] || return 1
	[[ $(zstd -dcq --long=27 -- "$d/$NATIVE_VARLIK" | sha256sum) == "$sha  -" ]]
}

derleme_hatasi() {
	tail -n 40 -- "$DERLEME_GUNLUGU" >&2 || true
	hata "$1 (günlük: $DERLEME_GUNLUGU)"
}

# native_derle: (d) native'i HEAD'in geçici bir worktree'sinde derler, o worktree'nin yükleyicisiyle dener ve
# önbelleğe koyar. Cargo hedef dizini önbellekte kalıcıdır; bağımlılıklar her seferinde yeniden derlenmez.
native_derle() {
	local hedef=$ONBELLEK/cargo-hedef baslangic sure wt kok sha glibc
	cpu_x86_64_v3 || hata "bu CPU x86-64-v3 değil; modern native burada derlenip denenemez"
	baslangic=$SECONDS
	DERLEME_DIZINI=$(mktemp -d "$ONBELLEK/derleme.XXXXXX")
	wt=$DERLEME_DIZINI/omp
	bilgi "native derleniyor (birkaç dakika sürer); günlük: $DERLEME_GUNLUGU"
	printf '== %s native derlemesi: anahtar %s, commit %s\n' "$(utc_simdi)" "$NATIVE_ANAHTAR" "$YAMALI_COMMIT" >"$DERLEME_GUNLUGU"
	git -C "$OMP_KAYNAK" -c core.hooksPath=/dev/null worktree add --detach "$wt" "$YAMALI_COMMIT" >>"$DERLEME_GUNLUGU" 2>&1 9>&- ||
		true
	# Kısmi (blob:none) klonda ilk checkout bir dosyayı atlayabiliyor; ikinci checkout eksik nesneyi çeker.
	if [[ -e $wt/.git && -n $(git -C "$wt" status --porcelain --untracked-files=no) ]]; then
		git -C "$wt" checkout -f HEAD -- . >>"$DERLEME_GUNLUGU" 2>&1 9>&- || true
	fi
	[[ -e $wt/.git && -z $(git -C "$wt" status --porcelain --untracked-files=no) ]] ||
		derleme_hatasi "geçici worktree eksiksiz oluşturulamadı"

	# build-bindings.ts cargo'ya --target-dir vermez: napi hedef dizinini CARGO_BUILD_TARGET_DIR'den, yoksa
	# cargo metadata'dan (CARGO_TARGET_DIR) okur; ikisi aynı olmalı. RUSTFLAGS boşsa betik modern varyant için
	# -C target-cpu=x86-64-v3 koyar, dışarıdan gelen bayraklar bunu ezmesin.
	if ! (cd -- "$wt" && "$BUN" install --frozen-lockfile &&
		env -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS -u CARGO_BUILD_TARGET -u OMP_NATIVE_FEATURES \
			PATH="$(dirname -- "$BUN"):$PATH" CARGO_TARGET_DIR="$hedef" CARGO_BUILD_TARGET_DIR="$hedef" \
			OMP_NATIVE_BUILD_BACKEND=cargo OMP_NATIVE_CARGO_PROFILE=ci \
			"$BUN" --cwd=packages/natives run build) >>"$DERLEME_GUNLUGU" 2>&1 9>&-; then
		derleme_hatasi "bun install ya da native derlemesi başarısız"
	fi
	[[ -f $wt/packages/natives/native/$NATIVE_MODERN ]] || derleme_hatasi "derleme $NATIVE_MODERN üretmedi"
	if [[ -e $wt/target ]] || ! compgen -G "$hedef/*/ci/libpi_natives.so" >/dev/null; then
		derleme_hatasi "cargo kalıcı hedef dizinini ($hedef) kullanmadı"
	fi

	# Worktree'nin kendi yükleyicisi tam bu dosyayı, damgası package.json sürümüyle aynı olarak yüklemeli.
	# PI_NATIVES_DIR geçici dizine: yükleyicinin ~/.omp/natives temizliği yayınlayanın omp'sine dokunmasın.
	kok=$(readlink -f -- "$wt")
	if ! (cd -- "$kok" && env -u PI_COMPILED -u __PI_NATIVE_VARIANT_CACHE PI_NATIVE_VARIANT=modern \
		PI_NATIVES_DIR="$GECICI/natives" DOSYA="$kok/packages/natives/native/$NATIVE_MODERN" "$BUN" -e '
			await import(`${process.argv[1]}/packages/natives/native/index.js`);
			const { nativeAddonStatus } = await import(`${process.argv[1]}/packages/natives/native/loader-state.js`);
			const s = nativeAddonStatus();
			if (s?.path !== process.env.DOSYA || s.stale) {
				console.error(`yüklenen native beklenen değil: ${JSON.stringify(s)}`);
				process.exit(1);
			}
			console.log(`yüklendi: ${s.path} (${s.version})`);
			process.exit(0);' "$kok") >>"$DERLEME_GUNLUGU" 2>&1 9>&-; then
		derleme_hatasi "derlenen native worktree'nin yükleyicisiyle yüklenemedi"
	fi
	sure=$((SECONDS - baslangic))

	YENI_NATIVE=$(mktemp -d "$ONBELLEK/native/.yeni.XXXXXX")
	cp --reflink=auto -- "$wt/packages/natives/native/$NATIVE_MODERN" "$YENI_NATIVE/$NATIVE_MODERN"
	derleme_kaldir
	zstd -q -19 --long=27 -T0 -o "$YENI_NATIVE/$NATIVE_VARLIK" -- "$YENI_NATIVE/$NATIVE_MODERN" 9>&-
	sha=$(sha256sum <"$YENI_NATIVE/$NATIVE_MODERN" | cut -d ' ' -f 1)
	glibc=$(native_glibc_gereksinimi "$YENI_NATIVE/$NATIVE_MODERN")
	[[ $glibc =~ ^[0-9]+\.[0-9]+$ ]] || hata "native'in glibc gereksinimi okunamadı"
	printf '%s\n' "NATIVE_ANAHTAR=$NATIVE_ANAHTAR" "NATIVE_SHA256=$sha" "NATIVE_GLIBC=$glibc" \
		"KAYNAK_COMMIT=$YAMALI_COMMIT" "SURUM=$SURUM" "DERLEME_ZAMANI=$(utc_simdi)" "DERLEME_SURESI=$sure" \
		>"$YENI_NATIVE/bilgi"
	rm -rf -- "$NATIVE_DIZINI"
	mv -T -- "$YENI_NATIVE" "$NATIVE_DIZINI"
	YENI_NATIVE=
	onbellek_tamam || hata "önbelleğe yazılan native doğrulanamadı: $NATIVE_DIZINI"
	bilgi "native derlendi: $sure sn, glibc >= $glibc, $NATIVE_VARLIK $(boyut "$NATIVE_DIZINI/$NATIVE_VARLIK")"
}

# tara <ad> <dosya> <yama|duz>: yayına girecek satırları $GECICI/gizli-desenler'e karşı tarar: yamada eklenen
# satırlar (baştaki + olmadan) ve dosya başlıkları, düz dosyada bütün satırlar. IZINLI_SATIR_DOSYASI'ndaki bir
# satırla birebir aynı olmayan her eşleşmeyi gösterip yayını durdurur.
tara() {
	local kod=0
	rm -f -- "$GECICI/bildirilecek"
	LC_ALL=C awk -v tur="$3" -v yer="$GECICI/tarama-yer" '
		tur == "duz" { print; print FNR >yer; next }
		/^diff --git / { baslik = 1 }
		/^@@ / { baslik = 0 }
		baslik && /^(diff --git |rename (from|to) |--- |\+\+\+ )/ { print; print FNR >yer }
		!baslik && /^\+/ { print substr($0, 2); print FNR >yer }' "$2" >"$GECICI/tarama"
	# -a ve LC_ALL=C: NUL ya da geçersiz UTF-8 içeren satırlar ikili sayılıp sonraki eşleşmeler atlanmasın.
	LC_ALL=C grep -anE -f "$GECICI/gizli-desenler" "$GECICI/tarama" >"$GECICI/supheli" || kod=$?
	((kod <= 1)) || hata "gizlilik taraması çalışmadı (grep çıkış kodu $kod)"
	((kod == 0)) || return 0
	LC_ALL=C awk -v ad="$1" -v izinli="$IZINLI_SATIR_DOSYASI" -v yer="$GECICI/tarama-yer" \
		-v cikti="$GECICI/bildirilecek" '
		BEGIN {
			while ((getline s <izinli) > 0) if (s != "" && s !~ /^#/) izin[s] = 1
			while ((getline s <yer) > 0) no[++n] = s
		}
		{
			i = index($0, ":")
			s = substr($0, i + 1)
			if (s in izin) next
			printf "  %s:%s: %s\n", ad, no[substr($0, 1, i - 1)], substr(s, 1, 300) >"/dev/stderr"
			print s >cikti
		}' "$GECICI/supheli"
	[[ -s $GECICI/bildirilecek ]] || return 0
	install -m 600 -- "$GECICI/bildirilecek" "$ONBELLEK/supheli-satirlar"
	hata "$1 içinde ev dizini yolu ya da gizli anahtara benzeyen satırlar var (yukarıda, satır numarasıyla). Yanlış alarmsa bu satırları $ONBELLEK/supheli-satirlar dosyasından olduğu gibi $IZINLI_SATIR_DOSYASI dosyasına ekle"
}

# readme_blogu: README'deki yamalar bloğunun içeriği.
readme_blogu() {
	local native dosya ekleme silme satirlar sayi
	if [[ $NATIVE_KAYNAK == npm ]]; then
		native="npm [\`$NPM_NATIVE_PAKETI@$NATIVE_NPM_SURUM\`](https://www.npmjs.com/package/$NPM_NATIVE_PAKETI/v/$NATIVE_NPM_SURUM)"
	else
		native="Releases [\`$RELEASE_ETIKETI\`](https://github.com/$OMP_YAMALARI_GH/releases/tag/$RELEASE_ETIKETI), \`glibc >= $NATIVE_GLIBC\`, x86-64-v3"
	fi
	read -r dosya ekleme silme < <(LC_ALL=C git --git-dir="$GITDIR" diff --shortstat --find-renames "$TABAN" "$YAMALI_COMMIT" |
		awk '{ for (i = 2; i <= NF; i++) { if ($i ~ /^files?$/) d = $(i - 1); if ($i ~ /^insertions?\(/) e = $(i - 1); if ($i ~ /^deletions?\(/) s = $(i - 1) } }
			END { print d + 0, e + 0, s + 0 }')
	satirlar=$(git --git-dir="$GITDIR" cherry -v "$TABAN" "$YAMALI_COMMIT" |
		sed -n 's/|/\\|/g; s/</\&lt;/g; s/^+ \([0-9a-f]\{12\}\)[0-9a-f]* \(.*\)$/| `\1` | \2 |/p')
	sayi=$(grep -c '^| `' <<<"$satirlar" || true)
	printf 'Son yayın: omp **%s**, %s · upstream tabanı [`%s`](%s/commit/%s) · native: %s\n\n' \
		"$SURUM" "$YAYIN_ZAMANI" "${TABAN:0:12}" "${OMP_UPSTREAM_URL_VARSAYILAN%.git}" "$TABAN" "$native"
	printf '%s dosya değişti: %s satır eklendi, %s satır silindi.\n\n' "$dosya" "$ekleme" "$silme"
	printf '<details>\n<summary>Değişen dosyalar (%s)</summary>\n\n```text\n' "$dosya"
	LC_ALL=C git --git-dir="$GITDIR" -c core.quotePath=false diff --stat=120 --find-renames "$TABAN" "$YAMALI_COMMIT" | sed '$d'
	printf '```\n\n</details>\n\n'
	printf "<details>\n<summary>Yama commit'leri (%s)</summary>\n\n| Commit | Konu |\n|---|---|\n%s\n\n</details>\n" "$sayi" "$satirlar"
}

# readme_uret: README.md'yi, yalnız iki işaret satırı arasındaki blok yenilenmiş olarak basar.
readme_uret() {
	local blok=$GECICI/readme-blogu
	readme_blogu >"$blok"
	awk -v blok="$blok" '
		$0 == "<!-- yamalar:basla -->" { print; while ((getline satir < blok) > 0) print satir; close(blok); icerde = 1; basla++; next }
		$0 == "<!-- yamalar:bitis -->" { if (!icerde) bozuk = 1; icerde = 0; bitis++ }
		!icerde { print }
		END { exit !(basla == 1 && bitis == 1 && !bozuk) }' "$REPO/README.md" ||
		hata "README.md'de <!-- yamalar:basla --> ve <!-- yamalar:bitis --> satırları birer kez ve bu sırayla bulunmalı"
}

release_notlari() {
	local b=$NATIVE_DIZINI/bilgi
	printf 'omp-yamalari için önceden derlenmiş `pi_natives` (linux-x64-modern: x86-64-v3, glibc >= %s).\n' "$NATIVE_GLIBC"
	printf 'zstd ile sıkıştırılmıştır; açmak için `zstd -d --long=27`.\n\n```text\n'
	printf '%s\n' "NATIVE_ANAHTAR=$NATIVE_ANAHTAR" "NATIVE_SHA256=$NATIVE_SHA256" "NATIVE_GLIBC=$NATIVE_GLIBC" \
		"KAYNAK_COMMIT=$(manifest_oku "$b" KAYNAK_COMMIT)" "SURUM=$(manifest_oku "$b" SURUM)"
	printf '```\n'
}

# release_olustur: önbellekteki native'i GitHub Releases'a yükler. Etiket bu yayının commit'ini gösterir;
# main'den (manifest'ten) önce yalnız etiket push edilir.
release_olustur() {
	local notlar=$GECICI/release-notlari.md dallar
	local -a olustur=(gh release create "$RELEASE_ETIKETI" --repo "$OMP_YAMALARI_GH" --verify-tag
		--title "native ${NATIVE_ANAHTAR:0:12}" --notes-file "$notlar" "$NATIVE_DIZINI/$NATIVE_VARLIK")
	release_notlari >"$notlar"
	if [[ -z $(git -C "$REPO" ls-remote origin "refs/tags/$RELEASE_ETIKETI" 9>&-) ]]; then
		git -C "$REPO" push -q origin "HEAD:refs/tags/$RELEASE_ETIKETI" 9>&- || hata "$RELEASE_ETIKETI etiketi push edilemedi"
	fi
	bilgi "GitHub Releases: $RELEASE_ETIKETI oluşturuluyor, $NATIVE_VARLIK yükleniyor"
	"${olustur[@]}" >/dev/null 9>&- && return 0
	# GitHub, hiç dalı olmayan yepyeni repoda release açmayı reddedebilir. Böyle bir repodan kurulmuş arkadaş
	# olamayacağı için yalnız o ilk yayında main önce gönderilir ve release bir kez daha denenir.
	dallar=$(git -C "$REPO" ls-remote --heads origin 9>&-) || hata "origin okunamadı"
	[[ -z $dallar ]] || hata "gh release create başarısız"
	bilgi "repoda henüz dal yok: önce main gönderiliyor, release yeniden deneniyor"
	git -C "$REPO" push -q origin main 9>&- || hata "git push origin main başarısız"
	"${olustur[@]}" >/dev/null 9>&- || hata "gh release create başarısız"
}

# dogrula: push'tan sonra yayını arkadaşın göreceği gibi denetler.
dogrula() {
	local yerel uzak indirme klon=$GECICI/klon agac
	bilgi "doğrulanıyor: origin main, native indirme adresi, taze klondaki yama"
	yerel=$(git -C "$REPO" rev-parse HEAD)
	uzak=$(git -C "$REPO" ls-remote origin refs/heads/main 9>&- | cut -f 1)
	[[ $uzak == "$yerel" ]] || hata "origin main ($uzak) yerel HEAD ($yerel) değil"
	if [[ $NATIVE_KAYNAK == npm ]]; then
		npm_native_sorgula "$NATIVE_NPM_SURUM" || hata "npm'de $NPM_NATIVE_PAKETI@$NATIVE_NPM_SURUM bulunamadı"
		indirme=$NPM_TARBALL
	else
		indirme=$NATIVE_URL
	fi
	curl -fsSIL -o /dev/null "$indirme" 9>&- || hata "native indirilemiyor: $indirme"
	git clone -q --depth 1 --branch main "$(git -C "$REPO" remote get-url origin)" "$klon" 9>&- || hata "repo klonlanamadı"
	cmp -s -- "$klon/yama.env" "$REPO/yama.env" || hata "klondaki yama.env yereldekiyle aynı değil"
	agac=$(yama_agaci "$GITDIR" "$TABAN" "$klon/yamalar.patch" 9>&-) || hata "klondaki yamalar.patch TABAN'a uygulanamadı"
	[[ $agac == "$AGAC" ]] || hata "klondaki yamalar.patch AGAC'ı vermiyor ($agac)"
}

ozet() {
	printf 'Özet:\n'
	printf '  omp sürümü      %s\n' "$SURUM"
	printf '  TABAN           %s\n' "$TABAN"
	printf '  AGAC            %s\n' "$AGAC"
	printf '  YAMALI_COMMIT   %s\n' "$YAMALI_COMMIT"
	printf '  yamalar.patch   %s bayt\n' "$(wc -c <"$REPO/yamalar.patch")"
	printf '  YAYIN_ZAMANI    %s (%s)\n' "$YAYIN_ZAMANI" "$ZAMAN_NOTU"
	printf '  native anahtarı %s\n' "$NATIVE_ANAHTAR"
	if [[ $NATIVE_KAYNAK == npm ]]; then
		printf '  native          npm %s@%s; %s\n' "$NPM_NATIVE_PAKETI" "$NATIVE_NPM_SURUM" "$NATIVE_YOLU"
	else
		printf '  native          Releases %s, glibc >= %s, x86-64-v3; %s\n' "$RELEASE_ETIKETI" "$NATIVE_GLIBC" "$NATIVE_YOLU"
	fi
	if ((RELEASE_GEREK)); then
		printf '  önbellek        %s\n' "$NATIVE_DIZINI"
		printf '                  .node %s, .zst %s, derleme süresi %s sn (%s)\n' \
			"$(boyut "$NATIVE_DIZINI/$NATIVE_MODERN")" "$(boyut "$NATIVE_DIZINI/$NATIVE_VARLIK")" \
			"$(manifest_oku "$NATIVE_DIZINI/bilgi" DERLEME_SURESI)" "$(manifest_oku "$NATIVE_DIZINI/bilgi" DERLEME_ZAMANI)"
		if ((KURU)); then
			printf '  Releases        kuru çalışma: %s oluşturulmadı\n' "$RELEASE_ETIKETI"
		else
			printf '  Releases        %s oluşturuldu\n' "$RELEASE_ETIKETI"
		fi
	fi
}

sonuc_yaz() {
	local native=$NATIVE_URL
	[[ $NATIVE_KAYNAK != npm ]] || native=$NATIVE_NPM_SURUM
	printf 'SONUC=%s\nSURUM=%s\nTABAN=%s\nNATIVE_KAYNAK=%s\nNATIVE=%s\n' "$1" "$SURUM" "$TABAN" "$NATIVE_KAYNAK" "$native"
}

case $#:${1-} in
0:) ;;
1:--kuru) KURU=1 ;;
1:-h | 1:--help)
	kullanim
	exit 0
	;;
*)
	kullanim >&2
	exit 2
	;;
esac

trap temizle EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[[ -x $BUN ]] || hata "bun bulunamadı (PATH'te ya da $HOME/.bun/bin/bun)"
for arac in git curl zstd objdump flock sha256sum numfmt; do
	command -v "$arac" >/dev/null || hata "$arac bulunamadı"
done
mkdir -p -- "$ONBELLEK/native"
# Gerçek yol: git worktree kayıtlarını symlink'siz yolla tutar, artiklari_temizle onlarla karşılaştırır.
ONBELLEK=$(cd -- "$ONBELLEK" && pwd -P)
DERLEME_GUNLUGU=$ONBELLEK/derleme.log
# Ağa çıkan ya da uzun süren alt süreçler kilit kapalı (9>&-) başlatılır: arkada kalan bir süreç (git'in eksik
# nesne çekerken bile başlattığı `maintenance run --detach`, bir derleme sunucusu) betik bitince kilidi tutmasın.
exec 9>"$ONBELLEK/kilit"
flock -n 9 || hata "başka bir yayinla.sh çalışıyor (kilit: $ONBELLEK/kilit)"
artiklari_temizle
GECICI=$(mktemp -d "${TMPDIR:-/tmp}/yayinla.XXXXXX")

GITDIR=$(git -C "$OMP_KAYNAK" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
	hata "$OMP_KAYNAK bir git deposu değil (OMP_KAYNAK ile değiştirilebilir)"
kirli=$(git -C "$OMP_KAYNAK" status --porcelain --untracked-files=no)
if [[ -n $kirli ]]; then
	printf '%s\n' "$kirli" >&2
	hata "$OMP_KAYNAK içinde commit edilmemiş değişiklikler var (yukarıda); yayın HEAD'den yapılır, önce commit et"
fi
if ((KURU)); then
	if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1 9>&-; then
		GH_VAR=0
		bilgi "uyarı: gh yok ya da oturum açık değil; GitHub Releases denetlenmeyecek"
	fi
else
	repo_denetle
fi

bilgi "omp kaynağı güncelleniyor: git -C $OMP_KAYNAK fetch origin"
git -C "$OMP_KAYNAK" fetch -q origin 9>&- || hata "git fetch origin başarısız"
UPSTREAM_URL=$(git -C "$OMP_KAYNAK" remote get-url origin)
etiketler=$(kararli_etiketler "$UPSTREAM_URL" 9>&-) ||
	hata "upstream'in kararlı sürüm etiketleri okunamadı ($UPSTREAM_URL); etiketsiz aramak npm'deki native'i atlayabilir"
mapfile -t SON_ETIKETLER < <(tail -n 10 <<<"$etiketler" | tac)
eksik=()
for t in "${SON_ETIKETLER[@]}"; do
	git -C "$OMP_KAYNAK" rev-parse -q --verify "refs/tags/$t^{commit}" >/dev/null || eksik+=("refs/tags/$t:refs/tags/$t")
done
if ((${#eksik[@]})); then
	git -C "$OMP_KAYNAK" fetch -q --no-tags origin "${eksik[@]}" 9>&- || hata "upstream etiketleri çekilemedi: ${eksik[*]}"
fi

YAMALI_COMMIT=$(git -C "$OMP_KAYNAK" rev-parse --verify 'HEAD^{commit}')
TABAN=$(git -C "$OMP_KAYNAK" merge-base "$YAMALI_COMMIT" refs/remotes/origin/main) ||
	hata "HEAD ile origin/main'in ortak atası bulunamadı"
[[ $TABAN != "$YAMALI_COMMIT" ]] || hata "HEAD upstream main'in içinde; yayınlanacak yama yok"
AGAC=$(git -C "$OMP_KAYNAK" rev-parse --verify "$YAMALI_COMMIT^{tree}")
SURUM=$(git -C "$OMP_KAYNAK" show "$YAMALI_COMMIT:packages/utils/package.json" |
	"$BUN" -e 'console.log((await Bun.stdin.json()).version)') || hata "packages/utils/package.json okunamadı"
[[ $SURUM =~ ^[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*$ ]] || hata "packages/utils/package.json sürümü geçersiz: $SURUM"
bilgi "omp $SURUM: HEAD ${YAMALI_COMMIT:0:12}, TABAN ${TABAN:0:12} (HEAD ile origin/main'in ortak atası)"

YAMA=$GECICI/yamalar.patch
yama_uret "$GITDIR" "$TABAN" "$YAMALI_COMMIT" >"$YAMA" 9>&-
{
	printf '%s\n' "${GIZLI_DESENLER[@]}"
	[[ ! -f $GIZLI_DESEN_DOSYASI ]] || sed 's/\r$//; /^[[:space:]]*$/d; /^#/d' "$GIZLI_DESEN_DOSYASI"
} >"$GECICI/gizli-desenler"
tara yamalar.patch "$YAMA" yama
agac=$(yama_agaci "$GITDIR" "$TABAN" "$YAMA" 9>&-) || hata "yamalar.patch TABAN'a uygulanamadı"
[[ $agac == "$AGAC" ]] || hata "TABAN + yamalar.patch ağacı ($agac) HEAD'in ağacı ($AGAC) değil"
bilgi "yama doğrulandı: $(wc -c <"$YAMA") bayt; TABAN + yamalar.patch = AGAC ${AGAC:0:12}"

NATIVE_ANAHTAR=$(native_anahtar "$GITDIR" "$YAMALI_COMMIT" 9>&-) && [[ $NATIVE_ANAHTAR =~ ^[0-9a-f]{64}$ ]] ||
	hata "native anahtarı hesaplanamadı"
RELEASE_ETIKETI=native-${NATIVE_ANAHTAR:0:12}
NATIVE_DIZINI=$ONBELLEK/native/$NATIVE_ANAHTAR
ONCEKI=$GECICI/onceki.env
git -C "$REPO" show HEAD:yama.env >"$ONCEKI" 2>/dev/null || : >"$ONCEKI"
bilgi "native anahtarı ${NATIVE_ANAHTAR:0:12}; kaynağı aranıyor"
if native_onceki; then
	NATIVE_YOLU="önceki yayındaki native korundu"
elif native_npm_ara; then
	NATIVE_YOLU="upstream v$NATIVE_NPM_SURUM ile aynı native anahtarı, npm'deki hazır native"
elif native_release_var; then
	NATIVE_YOLU="GitHub Releases'ta zaten yüklü"
else
	if onbellek_tamam; then
		NATIVE_YOLU="önbellekteki derleme kullanıldı, yeniden derlenmedi"
	else
		[[ ! -e $NATIVE_DIZINI ]] || bilgi "önbellekteki native eksik ya da bozuk; yeniden derlenecek"
		native_derle
		NATIVE_YOLU="bu çalışmada derlendi"
	fi
	native_release "$(manifest_oku "$NATIVE_DIZINI/bilgi" NATIVE_SHA256)" "$(manifest_oku "$NATIVE_DIZINI/bilgi" NATIVE_GLIBC)"
	RELEASE_GEREK=1
fi
bilgi "native: $NATIVE_KAYNAK; $NATIVE_YOLU"

YAYIN_ZAMANI=$(onceki YAYIN_ZAMANI)
if [[ -n $YAYIN_ZAMANI ]] && ayni_yayin; then
	ZAMAN_NOTU="TABAN, AGAC ve native önceki yayınla aynı: korundu"
else
	YAYIN_ZAMANI=$(utc_simdi)
	ZAMAN_NOTU=yeni
fi

readme_uret >"$GECICI/README.md" 9>&-
tara "README.md (yamalar bloğu)" "$GECICI/readme-blogu" duz
cp -- "$YAMA" "$REPO/yamalar.patch"
manifest_yaz >"$REPO/yama.env"
cp -- "$GECICI/README.md" "$REPO/README.md"

if ((KURU)); then
	ozet
	printf '\ngit status --short:\n'
	git -C "$REPO" status --short
	printf '\n'
	sonuc_yaz kuru
	exit 0
fi

SONUC=degisiklik-yok
# Çalışma sürerken (native derlemesi dakikalar sürebilir) repoya başka dosya eklenmiş olabilir.
repo_dosyalarini_denetle
git -C "$REPO" add -A
if ! git -C "$REPO" diff --cached --quiet; then
	git -C "$REPO" commit -q -m "yayın: omp $SURUM ($YAYIN_ZAMANI)" 9>&-
	bilgi "commit: $(git -C "$REPO" log -1 --format='%h %s')"
	SONUC=yayinlandi
fi
if ((RELEASE_GEREK)); then
	release_olustur
	SONUC=yayinlandi
fi
if [[ $(git -C "$REPO" ls-remote origin refs/heads/main 9>&- | cut -f 1) != "$(git -C "$REPO" rev-parse HEAD)" ]]; then
	bilgi "push: origin main"
	git -C "$REPO" push -q origin main 9>&- || hata "git push origin main başarısız"
	SONUC=yayinlandi
fi
dogrula
ozet
printf '\n'
sonuc_yaz "$SONUC"
