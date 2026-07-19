#!/bin/bash

# ===== COLORES PARA LA TERMINAL =====
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}   Instalador Automático del Bot AWS   ${NC}"
echo -e "${GREEN}=======================================${NC}"

# 1. PEDIR DATOS AL USUARIO (MENÚ INTERACTIVO)
echo -e "\n${CYAN}📝 PASO 1: DATOS DE INSTALACIÓN${NC}"
read -p "🔗 Ingresa el enlace de GitHub (ej. https://github.com/.../.git): " REPO_URL

if [ -z "$REPO_URL" ]; then
    echo -e "${RED}❌ Error: No ingresaste ningún enlace. Cancelando instalación.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}🔑 Ahora configuraremos las credenciales del bot:${NC}"
read -p "👉 Ingresa el TOKEN de tu bot de Telegram: " BOT_TOKEN
read -p "👉 Ingresa tu ID numérico de Telegram (Para ser el Admin): " ADMIN_ID

# Extraer el nombre de la carpeta a partir del enlace
REPO_NAME=$(basename -s .git "$REPO_URL")
INSTALL_DIR="/root/$REPO_NAME"

echo -e "\n${YELLOW}📁 El bot se instalará en: $INSTALL_DIR${NC}"

# 2. PREPARAR EL SISTEMA
echo -e "\n${CYAN}⚙️ PASO 2: ACTUALIZANDO SISTEMA${NC}"
apt-get update -y
apt-get install git python3 python3-pip python3-venv unzip -y

# 3. CLONAR EL REPOSITORIO
echo -e "\n${CYAN}📥 PASO 3: DESCARGANDO CÓDIGO${NC}"
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}⚠️ La carpeta ya existe. Limpiando archivos antiguos...${NC}"
    rm -rf "$INSTALL_DIR"
fi

cd /root
git clone "$REPO_URL"
cd "$INSTALL_DIR" || { echo -e "${RED}❌ Error al entrar a la carpeta del proyecto.${NC}"; exit 1; }

# === NUEVO: INYECTAR LOS DATOS DIRECTAMENTE EN EL CÓDIGO ===
echo -e "\n${CYAN}✏️ PASO 4: APLICANDO TUS DATOS AL CÓDIGO...${NC}"
if [ -f "$INSTALL_DIR/bot.py" ]; then
    # El comando 'sed' busca el texto temporal y lo reemplaza por lo que escribiste
    sed -i "s/PON_AQUI_TU_TOKEN_REAL/$BOT_TOKEN/g" "$INSTALL_DIR/bot.py"
    
    # Reemplaza el ID original (5489750950) por el nuevo ID que ingreses
    sed -i "s/5489750950/$ADMIN_ID/g" "$INSTALL_DIR/bot.py"
    
    echo -e "${GREEN}✅ Datos inyectados correctamente.${NC}"
else
    echo -e "${RED}⚠️ No se encontró bot.py para inyectar los datos.${NC}"
fi

# 4. CREAR EL ENTORNO VIRTUAL
echo -e "\n${CYAN}🐍 PASO 5: CREANDO ENTORNO VIRTUAL...${NC}"
python3 -m venv venv
source venv/bin/activate

# 5. INSTALAR LAS DEPENDENCIAS
echo -e "\n${CYAN}📦 PASO 6: INSTALANDO LIBRERÍAS...${NC}"
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
else
    pip install pyTelegramBotAPI boto3 requests
fi
deactivate

# 6. CREAR EL SERVICIO DE SYSTEMD
echo -e "\n${CYAN}🛠️ PASO 7: CREANDO SERVICIO 24/7...${NC}"
SERVICE_FILE="/etc/systemd/system/${REPO_NAME}.service"

cat <<EOL > "$SERVICE_FILE"
[Unit]
Description=Bot de Telegram AWS - $REPO_NAME
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

# 7. INICIAR EL BOT
echo -e "\n${CYAN}🚀 PASO 8: ARRANCANDO EL BOT...${NC}"
systemctl daemon-reload
systemctl enable "${REPO_NAME}.service"
systemctl restart "${REPO_NAME}.service"

# ===== MENSAJE FINAL =====
echo -e "\n${GREEN}=======================================${NC}"
echo -e "${GREEN}✅ ¡BOT INSTALADO Y CORRIENDO! ✅${NC}"
echo -e "${GREEN}=======================================${NC}"
echo -e "Ya no necesitas editar nada manualmente con 'nano'."
echo -e "Tu bot arrancó con el Token y el Admin que ingresaste."
echo -e ""
echo -e "🔹 ${YELLOW}Ver estado:${NC} systemctl status ${REPO_NAME}.service"
echo -e "🔹 ${YELLOW}Ver logs:${NC} journalctl -u ${REPO_NAME}.service -f"
echo -e "${GREEN}=======================================${NC}"
