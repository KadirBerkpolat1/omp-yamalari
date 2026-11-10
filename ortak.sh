# shellcheck shell=bash
# omp-yama (arkadaşın makinesi) ile yayinla.sh (yayınlayanın makinesi) arasındaki sözleşme.
# İki betik de bu dosyayı source eder; tek başına çalıştırılmaz. Buradaki bir değişiklik
# iki tarafın da aynı sonucu üretmesini bozmamalı: anahtar, yama ve commit biçimi sabit.

OMP_YAMALARI_GH=KadirBerkpolat1/omp-yamalari
OMP_UPSTREAM_URL_VARSAYILAN=https://github.com/can1357/oh-my-pi.git
NPM_NATIVE_PAKETI=@oh-my-pi/pi-natives-linux-x64
NATIVE_MODERN=pi_natives.linux-x64-modern.node
NATIVE_BASELINE=pi_natives.linux-x64-baseline.node

# manifest_oku <dosya> <ANAHTAR>: KEY=VALUE dosyasından değeri basar (yoksa boş). Dosya asla source edilmez.
manifest_oku() {
	sed -n "s/^$2=//p" "$1" | tail -n 1
}

# yama_uret <git-dir> <taban> <commit>: taban ile commit arasındaki ağaç farkı; kullanıcının git ayarlarından bağımsız.
yama_uret() {
	git --git-dir="$1" -c core.quotePath=false -c core.attributesFile=/dev/null diff --binary --full-index --find-renames \
		-U3 -O/dev/null --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ "$2" "$3"
}

# yama_agaci <git-dir> <taban> <yama-dosyası>: yamayı tabanın ağacına geçici bir index'te uygular, sonuç ağacını basar.
# Çalışma dizinine dokunmaz; çıplak (bare) depoda da çalışır.
yama_agaci() {
	local g=$1 taban=$2 yama=$3 idx agac
	idx=$(mktemp -u "${TMPDIR:-/tmp}/omp-yama-index.XXXXXX")
	if GIT_INDEX_FILE=$idx git --git-dir="$g" read-tree "$taban" &&
		GIT_INDEX_FILE=$idx git --git-dir="$g" apply --cached --binary --whitespace=nowarn "$yama" &&
		agac=$(GIT_INDEX_FILE=$idx git --git-dir="$g" write-tree); then
		rm -f "$idx"
		printf '%s\n' "$agac"
		return 0
	fi
	rm -f "$idx"
	return 1
}

# sabit_commit <git-dir> <tarih> <ağaç> <mesaj> [ebeveyn...]: kimliği ve tarihi sabit commit; her makinede aynı sha çıkar.
sabit_commit() {
	local g=$1 tarih=$2 agac=$3 mesaj=$4 p
	shift 4
	local ebeveynler=()
	for p in "$@"; do ebeveynler+=(-p "$p"); done
	GIT_AUTHOR_NAME=omp-yamalari GIT_AUTHOR_EMAIL=omp-yamalari@localhost GIT_AUTHOR_DATE=$tarih \
		GIT_COMMITTER_NAME=omp-yamalari GIT_COMMITTER_EMAIL=omp-yamalari@localhost GIT_COMMITTER_DATE=$tarih \
		git --git-dir="$g" -c commit.gpgSign=false -c i18n.commitEncoding=UTF-8 \
		commit-tree "$agac" "${ebeveynler[@]}" -m "$mesaj"
}

# native_anahtar <git-dir> <commit>: pi_natives derlemesinin girdilerinden sha256.
# Sürüm atlatması yalnız kök Cargo.toml'daki `version = "..."` satırını ve Cargo.lock'taki
# çalışma alanı paketlerinin (source satırı olmayan) sürümlerini değiştirir; ikisi de yok sayılır.
native_anahtar() {
	local g=$1 c=$2 agac toml kilit
	agac=$(git --git-dir="$g" -c core.quotePath=false ls-tree -r --full-tree "$c" -- crates rust-toolchain.toml .cargo \
		packages/natives/scripts/build-bindings.ts scripts/host-detect.ts scripts/bazel-natives.ts) || return 1
	toml=$(git --git-dir="$g" cat-file blob "$c:Cargo.toml") || return 1
	kilit=$(git --git-dir="$g" cat-file blob "$c:Cargo.lock") || return 1
	{
		printf '%s\n--- Cargo.toml\n' "$agac"
		printf '%s\n' "$toml" | LC_ALL=C grep -v '^version = "'
		printf -- '--- Cargo.lock\n'
		printf '%s\n' "$kilit" | LC_ALL=C awk 'BEGIN { RS = ""; ORS = "\n\n" } { sub(/\n+$/, "") } !/\nsource = / { gsub(/\nversion = "[^"]*"/, "") } { print }'
	} | sha256sum | cut -d ' ' -f 1
}

# kararli_etiketler <git-url>: upstream'in kararlı sürüm etiketleri (vX.Y.Z), eskiden yeniye.
kararli_etiketler() {
	git ls-remote --tags --refs "$1" 'refs/tags/v*' |
		sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/##p' |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}

# npm_native_bilgi <sürüm>: npm'deki native paketinin "<tarball-url> <integrity>" bilgisini basar.
npm_native_bilgi() {
	curl -fsSL "https://registry.npmjs.org/$NPM_NATIVE_PAKETI/$1" |
		"${BUN:-bun}" -e 'const j = await Bun.stdin.json(); console.log(`${j.dist.tarball} ${j.dist.integrity}`)'
}

# sri_dogrula <dosya> <sha512-...>: npm integrity (SRI) değerini doğrular.
sri_dogrula() {
	DOSYA=$1 BEKLENEN=$2 "${BUN:-bun}" -e '
		const h = new Bun.CryptoHasher("sha512");
		for await (const parca of Bun.file(process.env.DOSYA).stream()) h.update(parca);
		process.exit(`sha512-${h.digest("base64")}` === process.env.BEKLENEN ? 0 : 1);'
}

# surum_en_az <a> <b>: a >= b ise doğru (sort -V sırası).
surum_en_az() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

# glibc_surumu: sistemin glibc sürümü (ör. 2.44).
glibc_surumu() {
	getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }'
}

# native_glibc_gereksinimi <.node>: dosyanın istediği en yüksek GLIBC_ sürümü.
native_glibc_gereksinimi() {
	objdump -T "$1" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1
}

# cpu_varyanti: omp'nin yükleyicisiyle aynı kural (PI_NATIVE_VARIANT, yoksa /proc/cpuinfo'da avx2).
cpu_varyanti() {
	case ${PI_NATIVE_VARIANT:-} in
	modern | baseline) printf '%s\n' "$PI_NATIVE_VARIANT" ;;
	*) if grep -qiw avx2 /proc/cpuinfo; then echo modern; else echo baseline; fi ;;
	esac
}

# cpu_x86_64_v3: modern (x86-64-v3) derlemenin istediği bütün CPU bayrakları var mı.
cpu_x86_64_v3() {
	local bayraklar b
	bayraklar=" $(grep -m 1 '^flags' /proc/cpuinfo | cut -d : -f 2) "
	for b in avx avx2 bmi1 bmi2 fma f16c movbe abm xsave; do
		[[ $bayraklar == *" $b "* ]] || return 1
	done
}
