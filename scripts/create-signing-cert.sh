#!/bin/bash
# Creates the stable self-signed code-signing identity used for Mistary releases.
# A stable identity supports permission persistence; verify it on the target Mac.
# Ad-hoc rebuilds do not guarantee persistence. Run once manually; keep the backup safe.
set -euo pipefail

NAME="Mistary Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$HOME/Documents/Mistary Signing"
P12="${BACKUP_DIR}/mistary-signing.p12"
OPENSSL=/usr/bin/openssl

already_done() {
    if security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
        echo "钥匙串里已经有「${NAME}」，不需要重复创建。"
        exit 0
    fi
    if [[ -e "${P12}" ]]; then
        echo "备份文件已经存在，为避免覆盖已停止：${P12}"
        echo "如果钥匙串里的证书丢了，用它恢复：security import \"${P12}\" -k \"${KEYCHAIN}\" -T /usr/bin/codesign"
        exit 1
    fi
}
already_done

echo "将创建签名证书「${NAME}」，并导出一份加密备份到："
echo "  ${P12}"
echo
read -r -s -p "给备份文件设一个密码（至少 8 位）：" PASSWORD; echo
read -r -s -p "再输入一次：" CONFIRM; echo
[[ "${PASSWORD}" == "${CONFIRM}" ]] || { echo "两次输入不一致，已取消。"; exit 1; }
[[ ${#PASSWORD} -ge 8 ]] || { echo "密码至少 8 位，已取消。"; exit 1; }
# Check again: another run may have finished while this one waited for the password.
already_done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -config "${WORK}/cert.cnf" 2>/dev/null

mkdir -p "${BACKUP_DIR}"
P12PASS="${PASSWORD}" "${OPENSSL}" pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -name "${NAME}" -out "${P12}" -passout env:P12PASS
chmod 600 "${P12}"

echo "导入到登录钥匙串……"
security import "${P12}" -k "${KEYCHAIN}" -P "${PASSWORD}" -T /usr/bin/codesign >/dev/null
echo "设为可用于代码签名（系统会弹窗要你输入登录密码确认）……"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

if security find-identity -v -p codesigning "${KEYCHAIN}" | grep -q "${NAME}"; then
    echo
    echo "完成。以后 scripts/build-app.sh 会自动用「${NAME}」签名。"
    echo "第一次签名时如果弹出“codesign 想要访问钥匙串中的密钥”，点“始终允许”。"
    echo
    echo "请把备份文件和刚才的密码一起存进密码管理器："
    echo "  ${P12}"
    echo "证书丢失后，下一个版本会让所有用户重新授予一次完全磁盘访问权限。"
else
    echo "证书已导入，但没有出现在可用签名身份里。把上面的输出发给 Claude 看看。"
    exit 1
fi
