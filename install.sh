#!/bin/bash
# RustyManager Installer

TOTAL_STEPS=13
CURRENT_STEP=0

show_progress() {
    PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    echo "Progresso: [${PERCENT}%] - $1"
}

error_exit() {
    echo -e "\nErro: $1"
    return
}

increment_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

if [ "$EUID" -ne 0 ]; then
    error_exit "EXECUTE COMO ROOT"
else
    clear
    show_progress "Atualizando repositorios..."
    export DEBIAN_FRONTEND=noninteractive
    SCRIPT_VERSION="main"
    increment_step

    # ---->>>> Verificação do sistema
    show_progress "Verificando o sistema..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        VERSION=$VERSION_ID
    else
        error_exit "Não foi possível detectar o sistema operacional."
    fi
    increment_step

    # ---->>>> Verificação do sistema
    case $OS_NAME in
        ubuntu)
            case $VERSION in
                24.*|22.*|20.*|18.*)
                    show_progress "Sistema Ubuntu suportado, continuando..."
                    ;;
                *)
                    error_exit "Versão do Ubuntu não suportada. Use 18, 20, 22 ou 24."
                    ;;
            esac
            ;;
        debian)
            case $VERSION in
                12*|11*|10*|9*)
                    show_progress "Sistema Debian suportado, continuando..."
                    ;;
                *)
                    error_exit "Versão do Debian não suportada. Use 9, 10, 11 ou 12."
                    ;;
            esac
            ;;
        almalinux|rocky)
            case $VERSION in
                9*|8*)
                    show_progress "Sistema $OS_NAME suportado, continuando..."
                    ;;
                *)
                    error_exit "Versão do $OS_NAME não suportada. Use 8 ou 9."
                    ;;
            esac
            ;;
        *)
            error_exit "Sistema não suportado. Use Ubuntu, Debian, AlmaLinux ou Rocky Linux."
            ;;
    esac
    increment_step

    # ---->>>> Instalação de pacotes requisitos e atualização do sistema
    show_progress "Atualizando o sistema..."
    case $OS_NAME in
        ubuntu|debian)
            apt-get update -y > /dev/null 2>&1 || error_exit "Falha ao atualizar o sistema"
            apt-get install gnupg curl build-essential git cmake sysstat net-tools sqlite3 libsqlite3-dev zip tar iptables ca-certificates -y > /dev/null 2>&1 || error_exit "Falha ao instalar pacotes"
            ;;
        almalinux|rocky)
            dnf update -y > /dev/null 2>&1 || error_exit "Falha ao atualizar o sistema"
            dnf install epel-release gnupg2 curl gcc g++ make git cmake sysstat net-tools sqlite sqlite-devel zip tar iptables ca-certificates -y > /dev/null 2>&1 || error_exit "Falha ao instalar pacotes"
            ;;
    esac
    increment_step

    # ---->>>> Criando o diretorio do script
    show_progress "Criando diretorio /opt/rustymanager..."
    mkdir /opt/ > /dev/null 2>&1
    mkdir /opt/rustymanager > /dev/null 2>&1
    increment_step

    # ---->>>> Criando as colunas no banco de dados
    show_progress "Configurando o banco de dados..."
    sqlite3 /opt/rustymanager/db "
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        login_type TEXT NOT NULL,
        login_user TEXT NOT NULL,
        login_pass TEXT NOT NULL,
        login_limit TEXT NOT NULL,
        login_expiry TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS connections (
        id INTEGER PRIMARY KEY
    );
    "
    for column in "proxy_ports" "sslproxy_ports" "badvpn_ports" "checkuser_ports" "openvpn_port"; do
        column_exists=$(sqlite3 /opt/rustymanager/db "PRAGMA table_info(connections);" | grep -w "$column" | wc -l)
        if [ "$column_exists" -eq 0 ]; then
            sqlite3 /opt/rustymanager/db "ALTER TABLE connections ADD COLUMN $column TEXT;"
        fi
    done
    if [ $? -ne 0 ]; then
        error_exit "Falha ao configurar o banco de dados"
    fi
    increment_step

    # ---->>>> Instalar rust
    show_progress "Instalando Rust..."
    if ! command -v rustc &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > /dev/null 2>&1 || error_exit "Falha ao instalar Rust"
        . "$HOME/.cargo/env"
    fi
    increment_step

    # ---->>>> Instalar o RustyManager
    show_progress "Compilando RustyManager, isso pode levar bastante tempo dependendo da maquina..."
    mkdir -p /opt/rustymanager
    mkdir -p /opt/rustymanager/ssl
    git clone --branch "$SCRIPT_VERSION" --recurse-submodules --single-branch https://github.com/juniorfdtech/RustyManager.git /root/RustyManager > /dev/null 2>&1 || error_exit "Falha ao clonar RustyManager"

    cd /root/RustyManager/
    mv -f ./Utils/ssl/cert.pem /opt/rustymanager/ssl/cert.pem > /dev/null 2>&1
    mv -f ./Utils/ssl/key.pem /opt/rustymanager/ssl/key.pem > /dev/null 2>&1

    cargo build --release --jobs $(nproc) > /dev/null 2>&1 || error_exit "Falha ao compilar RustyManager"
    mv -f ./target/release/SshScript /opt/rustymanager/manager > /dev/null 2>&1
    mv -f ./target/release/CheckUser /opt/rustymanager/checkuser > /dev/null 2>&1
    mv -f ./target/release/RustyProxy /opt/rustymanager/rustyproxy > /dev/null 2>&1
    mv -f ./target/release/RustyProxySSL /opt/rustymanager/rustyproxyssl > /dev/null 2>&1
    mv -f ./target/release/ConnectionsManager /opt/rustymanager/connectionsmanager > /dev/null 2>&1

    increment_step

    # ---->>>> Compilar BadVPN
    show_progress "Compilando BadVPN..."
    mkdir -p /root/RustyManager/BadVpn/src/badvpn-build
    cd /root/RustyManager/BadVpn/src/badvpn-build
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1 || error_exit "Falha ao configurar cmake para BadVPN"
    make > /dev/null 2>&1 || error_exit "Falha ao compilar BadVPN"
    mv -f udpgw/badvpn-udpgw /opt/rustymanager/badvpn
    increment_step

    # ---->>>> Configuração de permissões
    show_progress "Configurando permissões..."
    chmod +x /opt/rustymanager/{manager,rustyproxy,rustyproxyssl,connectionsmanager,checkuser,badvpn}
    if [[ "$OS_NAME" == "almalinux" || "$OS_NAME" == "rockylinux" ]]; then
        sudo chcon -t bin_t /opt/rustymanager/{manager,rustyproxy,rustyproxyssl,connectionsmanager,checkuser,badvpn}
    fi
    ln -sf /opt/rustymanager/manager /usr/local/bin/menu
    increment_step


    # ---->>>> Instalar speedtest
    show_progress "Instalando Speedtest..."
    case $OS_NAME in
        ubuntu|debian)
            curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash > /dev/null 2>&1 || error_exit "Falha ao baixar e instalar o script do speedtest"
            apt-get install speedtest -y > /dev/null 2>&1 || error_exit "Falha ao instalar o speedtest"
            ;;
        almalinux|rocky)
            curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash > /dev/null 2>&1 || error_exit "Falha ao baixar e instalar o script do speedtest"
            dnf install speedtest -y > /dev/null 2>&1 || error_exit "Falha ao instalar o speedtest"
            ;;
    esac
    increment_step
    
    # ---->>>> Instalar Htop
    show_progress "Instalando monitor de recursos..."
    case $OS_NAME in
        ubuntu|debian)
            apt-get install htop -y > /dev/null 2>&1 || error_exit "Falha ao instalar o htop"
            ;;
        almalinux|rocky)
            dnf install htop -y > /dev/null 2>&1 || error_exit "Falha ao instalar o htop"
            ;;
    esac
    increment_step

    # ---->>>> Limpeza
    show_progress "Limpando diretórios temporários..."
    cd /root/
    rm -rf /root/RustyManager/
    increment_step

    # ---->>>> Instalação finalizada :)
    echo "Instalação concluída com sucesso. digite 'menu' para acessar o menu."
fi
