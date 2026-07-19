#!/bin/bash

# ===== COLORES PARA LA TERMINAL =====
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}   Instalador Automático del Bot AWS   ${NC}"
echo -e "${GREEN}=======================================${NC}"

# 1. PEDIR EL ENLACE DEL REPOSITORIO
read -p "🔗 Ingresa el enlace exacto de GitHub (ej. https://github.com/usuario/mi-bot.git): " REPO_URL

if [ -z "$REPO_URL" ]; then
    echo -e "${RED}❌ Error: No ingresaste ningún enlace. Cancelando instalación.${NC}"
    exit 1
fi

# Extraer el nombre de la carpeta a partir del enlace
REPO_NAME=$(basename -s .git "$REPO_URL")
INSTALL_DIR="/root/$REPO_NAME"

echo -e "\n${YELLOW}📁 El bot se instalará en la ruta: $INSTALL_DIR${NC}"

# 2. PREPARAR EL SISTEMA
echo -e "\n${YELLOW}⚙️  Actualizando el sistema e instalando herramientas base...${NC}"
apt-get update -y
apt-get install git python3 python3-pip python3-venv unzip -y

# 3. CLONAR EL REPOSITORIO
echo -e "\n${YELLOW}📥 Descargando el código desde GitHub...${NC}"
# Si la carpeta ya existe, la eliminamos para hacer una instalación limpia
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${RED}⚠️ La carpeta ya existe. Limpiando archivos antiguos...${NC}"
    rm -rf "$INSTALL_DIR"
fi

cd /root
git clone "$REPO_URL"
cd "$INSTALL_DIR" || { echo -e "${RED}❌ Error al entrar a la carpeta del proyecto.${NC}"; exit 1; }

# 4. CREAR EL ENTORNO VIRTUAL
echo -e "\n${YELLOW}🐍 Creando el entorno virtual (venv) aislado...${NC}"
python3 -m venv venv
source venv/bin/activate

# 5. INSTALAR LAS DEPENDENCIAS
echo -e "\n${YELLOW}📦 Instalando librerías de Python...${NC}"
# Si subes un requirements.txt lo usa, si no, instala las de tu bot por defecto
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
else
    echo -e "⚠️ No se encontró requirements.txt. Instalando pyTelegramBotAPI, boto3 y requests..."
    pip install pyTelegramBotAPI boto3 requests
fi
deactivate

# 6. CREAR EL SERVICIO DE SYSTEMD
echo -e "\n${YELLOW}🛠️  Configurando el servicio para ejecución 24/7...${NC}"
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
echo -e "\n${YELLOW}🚀 Arrancando el servicio del bot...${NC}"
systemctl daemon-reload
systemctl enable "${REPO_NAME}.service"
systemctl restart "${REPO_NAME}.service"

# ===== MENSAJE FINAL =====
echo -e "\n${GREEN}=======================================${NC}"
echo -e "${GREEN}✅ ¡INSTALACIÓN COMPLETADA CON ÉXITO! ✅${NC}"
echo -e "${GREEN}=======================================${NC}"
echo -e "Tu bot ya está corriendo en segundo plano como un servicio del sistema."
echo -e ""
echo -e "🔹 ${YELLOW}Ubicación del código:${NC} $INSTALL_DIR"
echo -e "🔹 ${YELLOW}Ver estado del bot:${NC} systemctl status ${REPO_NAME}.service"
echo -e "🔹 ${YELLOW}Ver registros en vivo:${NC} journalctl -u ${REPO_NAME}.service -f"
echo -e ""
echo -e "⚠️ ${RED}Nota importante:${NC} Si en tu código de GitHub dejaste el TOKEN vacío (ej. PON_AQUI_TU_TOKEN_REAL),"
echo -e "debes editarlo ahora ejecutando:"
echo -e "👉 ${YELLOW}nano $INSTALL_DIR/bot.py${NC}"
echo -e "Y luego reiniciar el bot con: ${YELLOW}systemctl restart ${REPO_NAME}.service${NC}"
echo -e "${GREEN}=======================================${NC}"
