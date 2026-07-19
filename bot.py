import time
import json
import subprocess
import tempfile
import os
import re
import boto3
import telebot
from botocore.exceptions import ClientError
from telebot.types import InlineKeyboardButton, InlineKeyboardMarkup

# ===== CONFIGURACIÓN =====
TOKEN = "PON_AQUI_TU_TOKEN_REAL"  # ← CAMBIAR POR TOKEN REAL
AWS_REGION = "us-east-1"

# IDs de administradores
ADMIN_IDS = [5489750950]

# Archivo para guardar admins
ADMIN_FILE = 'admins.json'

def cargar_admins():
    try:
        with open(ADMIN_FILE, 'r') as f:
            data = json.load(f)
            return data.get('admin_ids', ADMIN_IDS)
    except:
        with open(ADMIN_FILE, 'w') as f:
            json.dump({'admin_ids': ADMIN_IDS}, f, indent=2)
        return ADMIN_IDS

def guardar_admins():
    with open(ADMIN_FILE, 'w') as f:
        json.dump({'admin_ids': ADMIN_IDS}, f, indent=2)

ADMIN_IDS = cargar_admins()

# ===== INICIALIZACIÓN =====
bot = telebot.TeleBot(TOKEN, parse_mode="HTML")

# Inicializar clientes AWS
try:
    cloudfront = boto3.client("cloudfront", region_name=AWS_REGION)
    acm = boto3.client("acm", region_name=AWS_REGION)
    print("✅ AWS inicializado correctamente")
except Exception as e:
    print(f"⚠️ Error AWS: {e}")
    cloudfront = None
    acm = None

# Estados temporales de usuarios
user_states = {}

# ===== FUNCIONES AUXILIARES =====
def es_admin(user_id):
    return user_id in ADMIN_IDS

def es_admin_msg(message):
    return es_admin(message.chat.id)

def es_admin_call(call):
    return es_admin(call.message.chat.id)

def obtener_arn_por_id(short_id):
    try:
        certs = acm.list_certificates(CertificateStatuses=['ISSUED', 'PENDING_VALIDATION', 'VALIDATION_TIMED_OUT', 'FAILED']).get('CertificateSummaryList', [])
        for c in certs:
            if c['CertificateArn'].endswith(short_id):
                return c['CertificateArn']
    except:
        pass
    return None

# ===== MENÚS (SUBMENÚS APLICADOS) =====
def menu_principal():
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        InlineKeyboardButton("🌐 Gestión de CloudFront", callback_data="menu_cf"),
        InlineKeyboardButton("🔐 Gestión de Certificados ACM", callback_data="menu_acm"),
        InlineKeyboardButton("🧹 Invalidar Caché", callback_data="invalidar_menu"),
        InlineKeyboardButton("👥 Gestionar Administradores", callback_data="gestionar_admins"),
        InlineKeyboardButton("❓ Ayuda", callback_data="ayuda")
    )
    return markup

def menu_cloudfront():
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        InlineKeyboardButton("🚀 Crear CloudFront (CDN)", callback_data="crear_cf"),
        InlineKeyboardButton("📋 Listar Distribuciones", callback_data="listar_dists"),
        InlineKeyboardButton("🗑️ Gestionar/Eliminar Distribución", callback_data="gestionar_dists"),
        InlineKeyboardButton("🔙 Volver al Inicio", callback_data="volver_menu")
    )
    return markup

def menu_acm():
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        InlineKeyboardButton("🔒 Solicitar Certificado", callback_data="solicitar_acm"),
        InlineKeyboardButton("🔐 Gestionar Certificados", callback_data="gestionar_acm"),
        InlineKeyboardButton("🔙 Volver al Inicio", callback_data="volver_menu")
    )
    return markup

# ===== COMANDOS BÁSICOS =====
@bot.message_handler(commands=["start", "menu", "help"])
def cmd_start(message):
    if not es_admin_msg(message):
        bot.reply_to(message, "⛔ Acceso no autorizado")
        return
    bot.send_message(message.chat.id, "⚙️ <b>PANEL DE CONTROL AWS</b>\nSelecciona una categoría:", reply_markup=menu_principal())

@bot.message_handler(commands=["id"])
def cmd_id(message):
    chat_id = message.chat.id
    if message.reply_to_message:
        uid = message.reply_to_message.from_user.id
        name = message.reply_to_message.from_user.first_name
        bot.reply_to(message, f"👤 {name}\n🆔 <code>{uid}</code>")
    else:
        name = message.from_user.first_name
        is_admin = "✅ Admin" if es_admin(chat_id) else "❌ No admin"
        bot.reply_to(message, f"👤 {name}\n🆔 <code>{chat_id}</code>\n{is_admin}")

# ===== MANEJADOR DE BOTONES =====
@bot.callback_query_handler(func=lambda call: True)
def manejar_botones(call):
    if not es_admin_call(call):
        bot.answer_callback_query(call.id, "⛔ No autorizado", show_alert=True)
        return
    
    bot.answer_callback_query(call.id)
    chat_id = call.message.chat.id
    msg_id = call.message.message_id
    
    # NAVEGACIÓN DE MENÚS
    if call.data == "menu_cf":
        bot.edit_message_text("🌐 <b>GESTIÓN DE CLOUDFRONT</b>\nSelecciona una opción:", chat_id=chat_id, message_id=msg_id, reply_markup=menu_cloudfront())
        
    elif call.data == "menu_acm":
        bot.edit_message_text("🔐 <b>GESTIÓN DE CERTIFICADOS ACM</b>\nSelecciona una opción:", chat_id=chat_id, message_id=msg_id, reply_markup=menu_acm())
        
    elif call.data == "volver_menu":
        bot.edit_message_text("⚙️ <b>PANEL DE CONTROL AWS</b>\nSelecciona una categoría:", chat_id=chat_id, message_id=msg_id, reply_markup=menu_principal())
    
    # ACCIONES CLOUDFRONT
    elif call.data == "crear_cf":
        if not cloudfront:
            bot.send_message(chat_id, "❌ AWS no configurado")
            return
        user_states[chat_id] = {"accion": "crear_cf", "paso": 1}
        bot.edit_message_text("🚀 <b>CREAR CLOUDFRONT</b>\n\nPaso 1/2: Ingresa el <b>dominio personalizado/Alias</b>\nEjemplo: <code>cdn.tudominio.com</code>", chat_id=chat_id, message_id=msg_id)
    
    elif call.data == "listar_dists":
        if not cloudfront:
            bot.send_message(chat_id, "❌ AWS no configurado")
            return
        listar_distribuciones(chat_id)
    
    elif call.data == "gestionar_dists":
        if not cloudfront:
            bot.send_message(chat_id, "❌ AWS no configurado")
            return
        mostrar_dists_para_gestionar(chat_id, msg_id)
        
    elif call.data == "invalidar_menu":
        user_states[chat_id] = {"accion": "invalidar"}
        bot.edit_message_text("🧹 <b>INVALIDAR CACHÉ</b>\n\nIngresa el ID de la distribución:\nEjemplo: <code>E1A2B3C4D5E6F7</code>", chat_id=chat_id, message_id=msg_id)
    
    # ACCIONES ACM
    elif call.data == "solicitar_acm":
        if not acm:
            bot.send_message(chat_id, "❌ AWS no configurado")
            return
        user_states[chat_id] = {"accion": "solicitar_acm"}
        bot.edit_message_text("🔒 <b>SOLICITAR CERTIFICADO ACM</b>\n\nIngresa el dominio:\nEjemplo: <code>cdn.tudominio.com</code>", chat_id=chat_id, message_id=msg_id)
    
    elif call.data == "gestionar_acm":
        if not acm:
            bot.send_message(chat_id, "❌ AWS no configurado")
            return
        listar_certificados_acm(chat_id, msg_id)
    
    # ADMINS
    elif call.data == "gestionar_admins":
        menu_admins(chat_id, msg_id)
    
    elif call.data == "add_admin":
        user_states[chat_id] = {"accion": "add_admin"}
        bot.edit_message_text("➕ <b>AGREGAR ADMIN</b>\n\nEnvía el ID numérico o reenvía un mensaje del usuario.", chat_id=chat_id, message_id=msg_id)
    
    elif call.data == "list_admins":
        texto = "📋 <b>ADMINISTRADORES</b>\n\n"
        for i, aid in enumerate(ADMIN_IDS, 1):
            try:
                info = bot.get_chat(aid)
                texto += f"{i}. {info.first_name} - <code>{aid}</code>\n"
            except:
                texto += f"{i}. <code>{aid}</code>\n"
        texto += f"\nTotal: {len(ADMIN_IDS)}"
        markup = InlineKeyboardMarkup()
        markup.add(InlineKeyboardButton("🔙 Volver", callback_data="gestionar_admins"))
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    
    elif call.data == "remove_admin":
        if len(ADMIN_IDS) <= 1:
            bot.edit_message_text("⚠️ No puedes eliminar al único admin.", chat_id=chat_id, message_id=msg_id)
            return
        markup = InlineKeyboardMarkup(row_width=1)
        for aid in ADMIN_IDS:
            try:
                info = bot.get_chat(aid)
                nombre = f"{info.first_name} (@{info.username})" if info.username else info.first_name
            except:
                nombre = f"ID: {aid}"
            markup.add(InlineKeyboardButton(f"❌ {nombre}", callback_data=f"rm_admin_{aid}"))
        markup.add(InlineKeyboardButton("🔙 Cancelar", callback_data="gestionar_admins"))
        bot.edit_message_text("Selecciona admin a eliminar:", chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    
    elif call.data.startswith("rm_admin_"):
        uid = int(call.data.replace("rm_admin_", ""))
        if uid in ADMIN_IDS and len(ADMIN_IDS) > 1:
            ADMIN_IDS.remove(uid)
            guardar_admins()
            bot.edit_message_text(f"✅ Admin <code>{uid}</code> eliminado.", chat_id=chat_id, message_id=msg_id)
    
    # MANEJO ESPECÍFICO DE RECURSOS
    elif call.data.startswith("cert_acm_"):
        idx = int(call.data.replace("cert_acm_", ""))
        seleccionar_cert_acm(chat_id, msg_id, idx)
    
    elif call.data.startswith("acm_det_"):
        short_id = call.data.replace("acm_det_", "")
        ver_detalle_cert_acm(chat_id, msg_id, short_id)
    
    elif call.data.startswith("acm_delc_"):
        short_id = call.data.replace("acm_delc_", "")
        confirmar_eliminar_cert_acm(chat_id, msg_id, short_id)
    
    elif call.data.startswith("acm_del_"):
        short_id = call.data.replace("acm_del_", "")
        eliminar_cert_acm(chat_id, msg_id, short_id)
    
    elif call.data.startswith("gdist_"):
        dist_id = call.data.replace("gdist_", "")
        gestionar_dist_especifica(chat_id, msg_id, dist_id)
    
    elif call.data.startswith("disable_"):
        dist_id = call.data.replace("disable_", "")
        deshabilitar_dist(chat_id, msg_id, dist_id)
    
    elif call.data.startswith("delete_"):
        partes = call.data.split("_")
        dist_id = partes[1]
        etag = "_".join(partes[2:])
        eliminar_dist(chat_id, msg_id, dist_id, etag)
    
    elif call.data == "ayuda":
        texto = (
            "📚 <b>AYUDA DEL SISTEMA</b>\n\n"
            "🌐 <b>Gestión CloudFront:</b> Crear, listar y gestionar distribuciones CDN.\n"
            "🔐 <b>Certificados ACM:</b> Solicitar, ver y eliminar certificados SSL de AWS.\n"
            "🧹 <b>Invalidar Caché:</b> Limpiar el contenido de una distribución.\n"
            "👥 <b>Administradores:</b> Controla quién tiene acceso a este bot.\n\n"
            "Comandos: /start /menu /id /help"
        )
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=menu_principal())

# ===== MANEJAR ESTADOS (INPUT DE USUARIO) =====
@bot.message_handler(func=lambda m: es_admin_msg(m) and m.chat.id in user_states)
def manejar_input(message):
    chat_id = message.chat.id
    estado = user_states.get(chat_id, {})
    accion = estado.get("accion")
    
    if accion == "crear_cf":
        paso = estado.get("paso", 1)
        
        if paso == 1:
            dominio = message.text.strip()
            if not dominio or "." not in dominio:
                bot.reply_to(message, "⚠️ Dominio inválido")
                return
            estado["custom_domain"] = dominio
            estado["paso"] = 2
            user_states[chat_id] = estado
            bot.reply_to(message, f"✅ Dominio: <code>{dominio}</code>\n\nPaso 2/2: Ingresa el <b>origen</b>\nEjemplo: <code>vps.dominio.com</code>")
        
        elif paso == 2:
            origen = message.text.strip()
            if not origen:
                bot.reply_to(message, "⚠️ Origen inválido")
                return
            estado["origin"] = origen
            user_states[chat_id] = estado
            
            msg = bot.reply_to(message, "🔍 Buscando certificados ACM...")
            try:
                certs = acm.list_certificates(CertificateStatuses=['ISSUED'])['CertificateSummaryList']
                if not certs:
                    bot.edit_message_text("❌ No hay certificados validados en ACM.", chat_id=chat_id, message_id=msg.message_id)
                    del user_states[chat_id]
                    return
                
                markup = InlineKeyboardMarkup(row_width=1)
                estado["certs"] = []
                for i, cert in enumerate(certs[:10]):
                    estado["certs"].append({"domain": cert['DomainName'], "arn": cert['CertificateArn']})
                    markup.add(InlineKeyboardButton(f"🔒 {cert['DomainName']}", callback_data=f"cert_acm_{i}"))
                
                user_states[chat_id] = estado
                bot.edit_message_text("📜 <b>Selecciona el certificado a usar:</b>", chat_id=chat_id, message_id=msg.message_id, reply_markup=markup)
            except Exception as e:
                bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg.message_id)
                del user_states[chat_id]
    
    elif accion == "solicitar_acm":
        dominio = message.text.strip()
        if not dominio or "." not in dominio:
            bot.reply_to(message, "⚠️ Dominio inválido")
            return
        solicitar_certificado_acm(message, dominio)
        del user_states[chat_id]
    
    elif accion == "invalidar":
        dist_id = message.text.strip()
        if not dist_id:
            bot.reply_to(message, "⚠️ ID inválido")
            return
        invalidar_cache_dist(message, dist_id)
        del user_states[chat_id]
    
    elif accion == "add_admin":
        nuevo_id = None
        if message.forward_from:
            nuevo_id = message.forward_from.id
        elif message.text and message.text.strip().isdigit():
            nuevo_id = int(message.text.strip())
        
        if not nuevo_id:
            bot.reply_to(message, "⚠️ Envía un ID numérico o reenvía un mensaje")
            return
        
        if nuevo_id in ADMIN_IDS:
            bot.reply_to(message, "⚠️ Ya es administrador")
        else:
            ADMIN_IDS.append(nuevo_id)
            guardar_admins()
            bot.reply_to(message, f"✅ Admin agregado: <code>{nuevo_id}</code>")
        del user_states[chat_id]

# ===== FUNCIONES PRINCIPALES =====

def seleccionar_cert_acm(chat_id, msg_id, idx):
    estado = user_states.get(chat_id, {})
    certs = estado.get("certs", [])
    
    if idx >= len(certs):
        bot.send_message(chat_id, "❌ Selección inválida")
        return
    
    cert = certs[idx]
    dominio = estado.get("custom_domain")
    origen = estado.get("origin")
    
    bot.edit_message_text(f"⏳ Creando distribución...\nDominio: {dominio}\nOrigen: {origen}", chat_id=chat_id, message_id=msg_id)
    
    try:
        config = {
            "CallerReference": f"tg-{int(time.time() * 1000000)}",
            "Aliases": {"Quantity": 1, "Items": [dominio]},
            "Origins": {
                "Quantity": 1,
                "Items": [{
                    "Id": "origin-1",
                    "DomainName": origen,
                    "CustomOriginConfig": {
                        "HTTPPort": 80, "HTTPSPort": 443,
                        "OriginProtocolPolicy": "match-viewer",
                        "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
                    }
                }]
            },
            "DefaultCacheBehavior": {
                "TargetOriginId": "origin-1",
                "ForwardedValues": {
                    "QueryString": True,
                    "Cookies": {"Forward": "all"},
                    "Headers": {"Quantity": 1, "Items": ["*"]}
                },
                "TrustedSigners": {"Enabled": False, "Quantity": 0},
                "ViewerProtocolPolicy": "allow-all",
                "MinTTL": 0, "DefaultTTL": 0, "MaxTTL": 0
            },
            "Enabled": True,
            "Comment": f"VPN gRPC - {dominio}",
            "ViewerCertificate": {
                "ACMCertificateArn": cert['arn'],
                "SSLSupportMethod": "sni-only",
                "MinimumProtocolVersion": "TLSv1.2_2021"
            },
            "HttpVersion": "http2"
        }
        
        resp = cloudfront.create_distribution(DistributionConfig=config)
        dist = resp['Distribution']
        
        resultado = (
            f"✅ <b>¡CREADA CON ÉXITO!</b>\n\n"
            f"🆔 ID: <code>{dist['Id']}</code>\n"
            f"🌐 Host: <code>{dist['DomainName']}</code>\n"
            f"📊 Estado: <code>{dist['Status']}</code>\n\n"
            f"⚠️ Apunta <code>{dominio}</code> → <code>{dist['DomainName']}</code> (CNAME)\n"
            f"⏳ Tarda 5-10 min en desplegarse"
        )
        bot.edit_message_text(resultado, chat_id=chat_id, message_id=msg_id)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg_id)
    
    del user_states[chat_id]

def solicitar_certificado_acm(message, dominio):
    chat_id = message.chat.id
    msg = bot.reply_to(message, "⏳ Solicitando certificado...")
    
    try:
        arn = acm.request_certificate(DomainName=dominio, ValidationMethod='DNS')['CertificateArn']
        time.sleep(5)
        
        for _ in range(10):
            try:
                info = acm.describe_certificate(CertificateArn=arn)
                validacion = info['Certificate']['DomainValidationOptions']
                if validacion and 'ResourceRecord' in validacion[0]:
                    rec = validacion[0]['ResourceRecord']
                    resultado = (
                        f"✅ <b>Certificado solicitado</b>\n\n"
                        f"📋 <b>CNAME para validación DNS:</b>\n"
                        f"Nombre: <code>{rec['Name']}</code>\n"
                        f"Valor: <code>{rec['Value']}</code>\n\n"
                        f"🔄 Verificando automáticamente..."
                    )
                    bot.edit_message_text(resultado, chat_id=chat_id, message_id=msg.message_id)
                    
                    for i in range(60):
                        time.sleep(10)
                        status = acm.describe_certificate(CertificateArn=arn)['Certificate']['Status']
                        if status == 'ISSUED':
                            bot.edit_message_text(f"✅ <b>¡EMITIDO!</b>\n\nARN: <code>{arn}</code>", chat_id=chat_id, message_id=msg.message_id)
                            return
                        elif status == 'FAILED':
                            bot.edit_message_text("❌ Validación fallida", chat_id=chat_id, message_id=msg.message_id)
                            return
                    return
            except:
                time.sleep(3)
        
        bot.edit_message_text(f"⚠️ Tardando. ARN: <code>{arn}</code>", chat_id=chat_id, message_id=msg.message_id)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg.message_id)

def listar_certificados_acm(chat_id, msg_id):
    try:
        certs = acm.list_certificates(
            CertificateStatuses=['ISSUED', 'PENDING_VALIDATION', 'VALIDATION_TIMED_OUT', 'FAILED']
        ).get('CertificateSummaryList', [])
        
        if not certs:
            markup = InlineKeyboardMarkup()
            markup.add(InlineKeyboardButton("🔙 Volver", callback_data="menu_acm"))
            bot.edit_message_text("📭 <b>No hay certificados ACM</b>", chat_id=chat_id, message_id=msg_id, reply_markup=markup)
            return
        
        markup = InlineKeyboardMarkup(row_width=1)
        texto = f"🔐 <b>CERTIFICADOS ACM</b> ({len(certs)} encontrados)\n\n"
        
        for i, cert in enumerate(certs[:15]):
            domain = cert.get('DomainName', 'N/A')
            status = cert.get('CertificateStatus', 'N/A')
            
            if status == 'ISSUED': emoji = "🟢"
            elif status == 'PENDING_VALIDATION': emoji = "🟡"
            elif status == 'FAILED': emoji = "🔴"
            elif status == 'VALIDATION_TIMED_OUT': emoji = "⏰"
            else: emoji = "⚪"
            
            texto += f"{emoji} <b>{domain}</b>\n   Estado: {status}\n"
            short_id = cert['CertificateArn'].split('/')[-1]
            markup.add(InlineKeyboardButton(f"{emoji} {domain} - {status}", callback_data=f"acm_det_{short_id}"))
        
        markup.add(InlineKeyboardButton("🔙 Volver al menú ACM", callback_data="menu_acm"))
        if len(certs) > 15: texto += f"\n⚠️ Mostrando 15 de {len(certs)} certificados"
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    except Exception as e:
        bot.edit_message_text(f"❌ Error al listar certificados: {e}", chat_id=chat_id, message_id=msg_id)

def ver_detalle_cert_acm(chat_id, msg_id, short_id):
    try:
        cert_arn = obtener_arn_por_id(short_id)
        if not cert_arn:
            bot.edit_message_text("❌ Certificado no encontrado.", chat_id=chat_id, message_id=msg_id)
            return
            
        cert_info = acm.describe_certificate(CertificateArn=cert_arn)
        cert = cert_info['Certificate']
        
        domain = cert.get('DomainName', 'N/A')
        status = cert.get('Status', 'N/A')
        arn = cert.get('CertificateArn', 'N/A')
        created = str(cert.get('CreatedAt', 'N/A'))
        not_before = str(cert.get('NotBefore', 'N/A'))
        not_after = str(cert.get('NotAfter', 'N/A'))
        renewal = cert.get('RenewalEligibility', 'N/A')
        type_cert = cert.get('Type', 'N/A')
        
        sans = cert.get('SubjectAlternativeNames', [])
        sans_text = "\n".join([f"  • {san}" for san in sans]) if sans else "  Ninguno"
        validation_method = cert.get('DomainValidationOptions', [{}])[0].get('ValidationMethod', 'N/A')
        
        texto = (
            f"🔐 <b>DETALLE DEL CERTIFICADO</b>\n\n"
            f"🌐 <b>Dominio:</b> {domain}\n"
            f"📊 <b>Estado:</b> {status}\n"
            f"📝 <b>Tipo:</b> {type_cert}\n"
            f"🔑 <b>ARN:</b> <code>{arn[:50]}...</code>\n"
            f"✅ <b>Validación:</b> {validation_method}\n"
            f"🔄 <b>Renovación:</b> {renewal}\n"
            f"📅 <b>Creado:</b> {created}\n"
            f"📅 <b>Válido desde:</b> {not_before}\n"
            f"📅 <b>Válido hasta:</b> {not_after}\n\n"
            f"📋 <b>Dominios adicionales:</b>\n{sans_text}\n\n"
        )
        
        markup = InlineKeyboardMarkup(row_width=2)
        in_use = cert.get('InUseBy', [])
        if in_use:
            texto += f"\n\n⚠️ <b>EN USO POR:</b>\n"
            for item in in_use[:5]: texto += f"  • <code>{item}</code>\n"
            markup.add(InlineKeyboardButton("⚠️ Forzar Eliminación", callback_data=f"acm_delc_{short_id}"))
        else:
            markup.add(InlineKeyboardButton("🗑️ Eliminar Certificado", callback_data=f"acm_delc_{short_id}"))
        
        markup.add(
            InlineKeyboardButton("🔙 Volver a lista", callback_data="gestionar_acm"),
            InlineKeyboardButton("🏠 Menú principal", callback_data="volver_menu")
        )
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    except Exception as e:
        bot.edit_message_text(f"❌ Error al obtener detalles: {e}", chat_id=chat_id, message_id=msg_id)

def confirmar_eliminar_cert_acm(chat_id, msg_id, short_id):
    try:
        cert_arn = obtener_arn_por_id(short_id)
        if not cert_arn: return
        
        cert_info = acm.describe_certificate(CertificateArn=cert_arn)
        cert = cert_info['Certificate']
        domain = cert.get('DomainName', 'N/A')
        status = cert.get('Status', 'N/A')
        in_use = cert.get('InUseBy', [])
        
        texto = (f"⚠️ <b>¿ELIMINAR CERTIFICADO?</b>\n\n🌐 Dominio: <b>{domain}</b>\n📊 Estado: {status}\n")
        
        if in_use:
            texto += "\n🔴 <b>¡ADVERTENCIA!</b> Este certificado está en uso por:\n"
            for item in in_use: texto += f"  • <code>{item}</code>\n"
            texto += "\nSi lo eliminas, estos servicios DEJARÁN DE FUNCIONAR.\n"
        
        texto += "\n¿Estás completamente seguro?"
        
        markup = InlineKeyboardMarkup(row_width=2)
        markup.add(
            InlineKeyboardButton("✅ Sí, eliminar", callback_data=f"acm_del_{short_id}"),
            InlineKeyboardButton("❌ Cancelar", callback_data=f"acm_det_{short_id}")
        )
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg_id)

def eliminar_cert_acm(chat_id, msg_id, short_id):
    try:
        cert_arn = obtener_arn_por_id(short_id)
        if not cert_arn: return
        
        cert_info = acm.describe_certificate(CertificateArn=cert_arn)
        domain = cert_info['Certificate']['DomainName']
        
        acm.delete_certificate(CertificateArn=cert_arn)
        
        texto = (
            f"✅ <b>CERTIFICADO ELIMINADO</b>\n\n"
            f"🌐 Dominio: <b>{domain}</b>\n"
            f"🔑 ARN: <code>{cert_arn[:50]}...</code>\n"
        )
        
        markup = InlineKeyboardMarkup()
        markup.add(InlineKeyboardButton("🔙 Ver otros certificados", callback_data="gestionar_acm"))
        markup.add(InlineKeyboardButton("🏠 Menú principal", callback_data="volver_menu"))
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_msg = e.response['Error']['Message']
        if error_code == 'ResourceInUseException':
            bot.edit_message_text(f"❌ <b>No se puede eliminar</b>\nEl certificado está en uso por servicios de AWS.\nError: {error_msg}", chat_id=chat_id, message_id=msg_id)
        else:
            bot.edit_message_text(f"❌ <b>Error de AWS:</b>\n{error_code}: {error_msg}", chat_id=chat_id, message_id=msg_id)
    except Exception as e:
        bot.edit_message_text(f"❌ Error inesperado: {e}", chat_id=chat_id, message_id=msg_id)

def listar_distribuciones(chat_id):
    try:
        bot.send_message(chat_id, "⏳ Obteniendo distribuciones...")
        dists = cloudfront.list_distributions().get('DistributionList', {}).get('Items', [])
        
        if not dists:
            bot.send_message(chat_id, "📭 No hay distribuciones de CloudFront.")
            return
            
        texto = f"📋 <b>DISTRIBUCIONES ({len(dists)})</b>\n\n"
        for d in dists:
            texto += f"🆔 <code>{d['Id']}</code>\n"
            texto += f"🌐 {d['DomainName']}\n"
            texto += f"📊 Estado: {d['Status']}\n"
            texto += f"🔌 Habilitada: {'✅' if d['Enabled'] else '❌'}\n\n"
            
        bot.send_message(chat_id, texto)
    except Exception as e:
        bot.send_message(chat_id, f"❌ Error: {e}")

def mostrar_dists_para_gestionar(chat_id, msg_id):
    try:
        dists = cloudfront.list_distributions().get('DistributionList', {}).get('Items', [])
        if not dists:
            markup = InlineKeyboardMarkup()
            markup.add(InlineKeyboardButton("🔙 Volver", callback_data="menu_cf"))
            bot.edit_message_text("📭 No hay distribuciones para gestionar.", chat_id=chat_id, message_id=msg_id, reply_markup=markup)
            return
            
        markup = InlineKeyboardMarkup(row_width=1)
        for d in dists[:10]: 
            status_icon = "🟢" if d['Status'] == "Deployed" else "🟡"
            markup.add(InlineKeyboardButton(f"{status_icon} {d['DomainName']}", callback_data=f"gdist_{d['Id']}"))
            
        markup.add(InlineKeyboardButton("🔙 Volver al menú CloudFront", callback_data="menu_cf"))
        bot.edit_message_text("⚙️ <b>Selecciona una distribución:</b>", chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg_id)

def gestionar_dist_especifica(chat_id, msg_id, dist_id):
    try:
        dist = cloudfront.get_distribution(Id=dist_id)
        d = dist['Distribution']
        etag = dist['ETag']
        
        texto = (
            f"⚙️ <b>GESTIONAR DISTRIBUCIÓN</b>\n\n"
            f"🆔 ID: <code>{d['Id']}</code>\n"
            f"🌐 Dominio: <code>{d['DomainName']}</code>\n"
            f"📊 Estado: {d['Status']}\n"
            f"🔌 Habilitada: {'✅ Sí' if d['DistributionConfig']['Enabled'] else '❌ No'}\n"
        )
        
        markup = InlineKeyboardMarkup(row_width=1)
        if d['DistributionConfig']['Enabled']:
            markup.add(InlineKeyboardButton("⏸️ Deshabilitar", callback_data=f"disable_{d['Id']}"))
        else:
            if d['Status'] == 'Deployed':
                markup.add(InlineKeyboardButton("🗑️ Eliminar", callback_data=f"delete_{d['Id']}_{etag}"))
            else:
                texto += "\n⚠️ <i>Debes esperar a que termine de desplegarse para eliminarla.</i>"
                
        markup.add(InlineKeyboardButton("🔙 Volver a lista", callback_data="gestionar_dists"))
        bot.edit_message_text(texto, chat_id=chat_id, message_id=msg_id, reply_markup=markup)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg_id)

def deshabilitar_dist(chat_id, msg_id, dist_id):
    try:
        dist = cloudfront.get_distribution_config(Id=dist_id)
        config = dist['DistributionConfig']
        etag = dist['ETag']
        
        config['Enabled'] = False
        
        cloudfront.update_distribution(DistributionConfig=config, Id=dist_id, IfMatch=etag)
        bot.edit_message_text(f"✅ Distribución <code>{dist_id}</code> deshabilitada.\n⏳ Espera a que se despliegue para poder eliminarla.", chat_id=chat_id, message_id=msg_id)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg_id)

def eliminar_dist(chat_id, msg_id, dist_id, etag):
    try:
        cloudfront.delete_distribution(Id=dist_id, IfMatch=etag)
        bot.edit_message_text(f"✅ Distribución <code>{dist_id}</code> eliminada permanentemente.", chat_id=chat_id, message_id=msg_id)
    except Exception as e:
        bot.edit_message_text(f"❌ Error (asegúrate que esté deshabilitada y deployed): {e}", chat_id=chat_id, message_id=msg_id)

def invalidar_cache_dist(message, dist_id):
    chat_id = message.chat.id
    msg = bot.reply_to(message, "⏳ Iniciando invalidación de caché...")
    try:
        resp = cloudfront.create_invalidation(
            DistributionId=dist_id,
            InvalidationBatch={
                'Paths': {'Quantity': 1, 'Items': ['/*']},
                'CallerReference': str(time.time())
            }
        )
        inv_id = resp['Invalidation']['Id']
        bot.edit_message_text(f"✅ <b>Caché invalidada</b>\n🆔 Invalidation ID: <code>{inv_id}</code>\nDistribución: <code>{dist_id}</code>", chat_id=chat_id, message_id=msg.message_id)
    except Exception as e:
        bot.edit_message_text(f"❌ Error: {e}", chat_id=chat_id, message_id=msg.message_id)

def menu_admins(chat_id, msg_id):
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        InlineKeyboardButton("➕ Agregar Admin", callback_data="add_admin"),
        InlineKeyboardButton("📋 Ver Admins", callback_data="list_admins"),
        InlineKeyboardButton("❌ Eliminar Admin", callback_data="remove_admin"),
        InlineKeyboardButton("🔙 Volver al inicio", callback_data="volver_menu")
    )
    bot.edit_message_text("👥 <b>GESTIÓN DE ADMINISTRADORES</b>\nSelecciona una opción:", chat_id=chat_id, message_id=msg_id, reply_markup=markup)


# ===== ARRANQUE DEL BOT =====
if __name__ == "__main__":
    print("🤖 Bot iniciado correctamente...")
    bot.infinity_polling()

