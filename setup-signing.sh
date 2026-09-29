#!/bin/zsh
# 프로젝트 전용 자체 서명 인증서를 .signing/ 안의 별도 키체인에 만든다 (로그인 키체인은 건드리지 않음).
# 서명이 빌드마다 바뀌지 않아야 손쉬운 사용·화면 기록 권한이 다시 빌드해도 유지된다.
set -euo pipefail
umask 077   # 개인 키와 비밀번호 파일을 나만 읽을 수 있게
cd "$(dirname "$0")"
mkdir -p .signing && cd .signing
KC="$PWD/rainpane-dev.keychain-db"
if [[ -f "$KC" ]]; then
  if [[ -f password ]] && security find-identity -p codesigning "$KC" | grep -q "Rainpane Local Dev"; then
    echo "이미 있음: $KC"; exit 0
  fi
  # 만들다 만 키체인: 지우고 다시 만든다
  security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
fi
trap 'rm -f key.pem id.p12' EXIT   # 실패해도 개인 키 파일을 남기지 않는다
# 이 키체인 전용 비밀번호. 컴퓨터마다 무작위로 만들어 .signing/password에 둔다 (build.sh가 읽는다)
PW=$(openssl rand -hex 16)
print -r -- "$PW" > password
cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Rainpane Local Dev
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
# macOS 키체인은 OpenSSL 3의 기본 PKCS12 형식을 못 읽어서 -legacy (macOS 기본 LibreSSL은 옵션이 없고 원래 옛 형식)
LEGACY=()
openssl pkcs12 -help 2>&1 | grep -q -- -legacy && LEGACY=(-legacy)
openssl pkcs12 -export $LEGACY -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PW" -name "Rainpane Local Dev"
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import id.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security find-identity -p codesigning "$KC"
