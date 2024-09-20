#!/bin/bash
#
# -------------------------------------------------------------
# 自动创建 Docker TLS 证书
# -------------------------------------------------------------

clear

# 生成随机密码的函数
generate_random_password() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# 获取公网 IPv4 地址的函数
get_public_ip() {
  curl -s ip.sb -4
}

# 读取用户输入，提供默认选项
read -p "请输入密码（回车默认使用随机密码）：" password
password=${password:-$(generate_random_password)}

read -p "请输入域名或 IP 地址（默认：$(get_public_ip)）：" domain_or_ip
domain_or_ip=${domain_or_ip:-$(get_public_ip)}

read -p "请输入国家（默认：CN）：" country
country=${country:-CN}

read -p "请输入省份（默认：Shanghai）：" state
state=${state:-Shanghai}

read -p "请输入城市（默认：Shanghai）：" city
city=${city:-Shanghai}

read -p "请输入组织名称（默认：LISIR）：" organization
organization=${organization:-LISIR}

read -p "请输入组织单位（默认：LISIR）：" organizational_unit
organizational_unit=${organizational_unit:-LISIR}

read -p "请输入电子邮件（默认：email@example.com）：" email
email=${email:-email@example.com}

# 确认用户输入的信息
echo -e "\n请确认以下信息：
密码: $password
国家: $country
省份: $state
城市: $city
组织名称: $organization
组织单位: $organizational_unit
电子邮件: $email
域名或 IP 地址: $domain_or_ip

按 Enter 键继续或按 Ctrl+C 退出..."
read -s -n 1

# 设置信息为变量
PASSWORD=$password
COUNTRY=$country
STATE=$state
CITY=$city
ORGANIZATION=$organization
ORGANIZATIONAL_UNIT=$organizational_unit
EMAIL=$email
CODE="docker_api"
COMMON_NAME="$domain_or_ip"

# 使用 mktemp 创建一个唯一的临时目录，用于存储证书
WORKDIR=$(mktemp -d -t docker_api_temp.XXXXXX)

# 确保工作目录成功创建
if [ ! -d "$WORKDIR" ]; then
  echo "无法创建临时工作目录。正在退出..."
  exit 1
fi

# 设置 OpenSSL 随机文件位置为临时目录
export RANDFILE="$WORKDIR/.rnd"

cd "$WORKDIR"

# 生成 CA 密钥
openssl genrsa -aes256 -passout "pass:$PASSWORD" -out "ca-key-$CODE.pem" 4096 >/dev/null 2>&1

# 生成 CA 证书
openssl req -new -x509 -days 365 -key "ca-key-$CODE.pem" -sha256 -out "ca-$CODE.pem" -passin "pass:$PASSWORD" -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=$COMMON_NAME/emailAddress=$EMAIL" >/dev/null 2>&1

# 生成服务器密钥和证书请求文件
openssl genrsa -out "server-key-$CODE.pem" 4096 >/dev/null 2>&1
openssl req -subj "/CN=$COMMON_NAME" -sha256 -new -key "server-key-$CODE.pem" -out server.csr >/dev/null 2>&1

# 配置服务器证书的扩展文件
cat <<EOF > extfile.cnf
subjectAltName = DNS:$domain_or_ip,IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

# 使用 CA 签发服务器证书
openssl x509 -req -days 365 -sha256 -in server.csr -passin "pass:$PASSWORD" -CA "ca-$CODE.pem" -CAkey "ca-key-$CODE.pem" -CAcreateserial -out "server-cert-$CODE.pem" -extfile extfile.cnf >/dev/null 2>&1

# 生成客户端密钥和证书请求文件
openssl genrsa -out "key-$CODE.pem" 4096 >/dev/null 2>&1
openssl req -subj '/CN=client' -new -key "key-$CODE.pem" -out client.csr >/dev/null 2>&1

# 配置客户端证书的扩展文件
echo "extendedKeyUsage = clientAuth" > extfile.cnf

# 使用 CA 签发客户端证书
openssl x509 -req -days 365 -sha256 -in client.csr -passin "pass:$PASSWORD" -CA "ca-$CODE.pem" -CAkey "ca-key-$CODE.pem" -CAcreateserial -out "cert-$CODE.pem" -extfile extfile.cnf >/dev/null 2>&1

# 删除临时的 CSR 文件
rm -f client.csr server.csr

# 设置文件权限
chmod 0400 "ca-key-$CODE.pem" "key-$CODE.pem" "server-key-$CODE.pem"
chmod 0444 "ca-$CODE.pem" "server-cert-$CODE.pem" "cert-$CODE.pem"

# 打包客户端证书
CLIENT_CERT_DIR="tls-client-certs-$CODE"
CLIENT_CERT_ARCHIVE="$CLIENT_CERT_DIR.tar.gz"
mkdir -p "$CLIENT_CERT_DIR"
cp -f "ca-$CODE.pem" "cert-$CODE.pem" "key-$CODE.pem" "$CLIENT_CERT_DIR/"
tar zcf "$CLIENT_CERT_ARCHIVE" -C "$CLIENT_CERT_DIR" .

# 移动客户端证书压缩包到 Docker 证书目录
DOCKER_CERT_DIR="/root/.docker/certs"
mkdir -p "$DOCKER_CERT_DIR"
mv "$CLIENT_CERT_ARCHIVE" "$DOCKER_CERT_DIR/"
mv "ca-$CODE.pem" "server-cert-$CODE.pem" "server-key-$CODE.pem" "$DOCKER_CERT_DIR/"

# 清理工作目录
cd ..
rm -r "$WORKDIR"

echo "客户端和服务端证书已成功生成并移动到 $DOCKER_CERT_DIR"

# 启用 Docker API
DOCKER_SERVICE_FILE="/lib/systemd/system/docker.service"
DOCKER_API_OPTIONS="-H=tcp://0.0.0.0:2376 --tlsverify --tlscacert=/root/.docker/certs/ca-docker_api.pem --tlscert=/root/.docker/certs/server-cert-docker_api.pem --tlskey=/root/.docker/certs/server-key-docker_api.pem"
NEW_EXEC_START="/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock $DOCKER_API_OPTIONS"

# 检查是否已存在 API 配置
if grep -q -- "$DOCKER_API_OPTIONS" "$DOCKER_SERVICE_FILE"; then
  echo "Docker API 配置已经存在。跳过..."
else
  echo "修改 Docker 服务以启用 API..."
  sed -i "s|^ExecStart=.*|ExecStart=$NEW_EXEC_START|" "$DOCKER_SERVICE_FILE"
  
  # 重新加载服务并重启 Docker
  if systemctl daemon-reload && systemctl restart docker; then
    echo "Docker API 已启用。"
  else
    echo "启用 Docker API 时出错。正在退出..."
    exit 1
  fi
fi
