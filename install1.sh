import json
import logging
import os
import threading
import time
from pathlib import Path

import boto3
import telebot
from botocore.exceptions import ClientError
from telebot.types import InlineKeyboardButton, InlineKeyboardMarkup

TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "PON_AQUI_TU_TOKEN_REAL")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
ADMIN_FILE = Path(os.getenv("ADMIN_FILE", "admins.json"))
INITIAL_ADMIN_ID = int(os.getenv("ADMIN_ID", "5489750950"))

if TOKEN == "PON_AQUI_TU_TOKEN_REAL":
    raise RuntimeError(
        "Configura la variable TELEGRAM_BOT_TOKEN antes de iniciar el bot."
    )

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s"
)

logger = logging.getLogger("aws-control-bot")
file_lock = threading.Lock()

bot = telebot.TeleBot(TOKEN, parse_mode="HTML")

# ============================================================
# ESTADO DEL USUARIO Y CUENTAS AWS
# ============================================================
user_states = {}
user_active_account = {}  # Guarda la cuenta activa por chat_id: "default" o "Superjabi"

def get_aws_session(chat_id):
    """Devuelve la sesión de AWS basada en la cuenta activa del usuario."""
    profile = user_active_account.get(chat_id, "default")
    try:
        if profile == "default":
            # Usa las credenciales por defecto
            return boto3.Session()
        else:
            # Usa el perfil específico (ej. "Superjabi")
            return boto3.Session(profile_name=profile)
    except Exception as e:
        logger.error(f"Error creando sesión AWS para perfil {profile}: {e}")
        return boto3.Session()

def get_cf(chat_id):
    return get_aws_session(chat_id).client("cloudfront", region_name=AWS_REGION)

def get_acm(chat_id):
    return get_aws_session(chat_id).client("acm", region_name=AWS_REGION)

# ============================================================
# ADMINISTRADORES
# ============================================================

def load_admins():
    try:
        with ADMIN_FILE.open("r", encoding="utf-8") as file:
            data = json.load(file)

        admins = {
            int(admin_id)
            for admin_id in data.get("admin_ids", [])
            if str(admin_id).isdigit()
        }

        admins.add(INITIAL_ADMIN_ID)
        return sorted(admins)

    except (FileNotFoundError, json.JSONDecodeError, OSError):
        save_admins([INITIAL_ADMIN_ID])
        return [INITIAL_ADMIN_ID]


def save_admins(admins=None):
    values = sorted(set(admins if admins is not None else ADMIN_IDS))

    with file_lock:
        with ADMIN_FILE.open("w", encoding="utf-8") as file:
            json.dump({"admin_ids": values}, file, indent=2)

ADMIN_IDS = load_admins()

def is_admin(user_id):
    return int(user_id) in ADMIN_IDS

def is_super_admin(user_id):
    return int(user_id) == INITIAL_ADMIN_ID

def authorized_message(message):
    if not is_admin(message.chat.id):
        bot.reply_to(message, "⛔ <b>Acceso no autorizado.</b>")
        return False
    return True

def authorized_callback(call):
    if not is_admin(call.from_user.id):
        bot.answer_callback_query(
            call.id,
            "⛔ No tienes autorización.",
            show_alert=True
        )
        return False
    return True

# ============================================================
# UTILIDADES
# ============================================================

def safe_error(error):
    if isinstance(error, ClientError):
        data = error.response.get("Error", {})
        return (
            f"{data.get('Code', 'AWS_ERROR')}: "
            f"{data.get('Message', str(error))}"
        )
    return str(error)

def callback_button(text, value):
    return InlineKeyboardButton(text, callback_data=value)

def back_button(callback_data="menu_principal"):
    markup = InlineKeyboardMarkup()
    markup.add(callback_button("🔙 Volver", callback_data))
    return markup

def clear_state(chat_id):
    user_states.pop(chat_id, None)

def get_distribution(distribution_id, chat_id):
    return get_cf(chat_id).get_distribution(Id=distribution_id)

def distribution_name(distribution):
    aliases = distribution.get("DistributionConfig", {}).get("Aliases", {})
    items = aliases.get("Items", [])
    return items[0] if items else distribution.get("DomainName", "Sin alias")

def valid_domain(value):
    return bool(value) and len(value) <= 253 and "." in value and " " not in value

def valid_distribution_id(value):
    return bool(value) and value.isalnum()

def get_acm_arn_for_domain(domain, chat_id):
    try:
        acm_client = get_acm(chat_id)
        parts = domain.split(".")
        wildcard = f"*.{'.'.join(parts[1:])}" if len(parts) > 1 else None
        
        paginator = acm_client.get_paginator('list_certificates')
        for page in paginator.paginate(CertificateStatuses=['ISSUED']):
            for cert in page.get('CertificateSummaryList', []):
                cert_domain = cert.get('DomainName', '')
                if cert_domain == domain or cert_domain == wildcard:
                    return cert['CertificateArn']
        return None
    except Exception as e:
        logger.error(f"Error al buscar certificado ACM: {e}")
        return None

# ============================================================
# MENÚS
# ============================================================

def main_menu(chat_id):
    profile = user_active_account.get(chat_id, "default")
    account_name = "Principal" if profile == "default" else "Superjabi"

    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        callback_button(f"🔄 Cuenta activa: {account_name} (Toca para cambiar)", "switch_account"),
        callback_button("🌐 Gestión CloudFront", "menu_cf"),
        callback_button("🔐 Gestión certificados ACM", "menu_acm"),
        callback_button("🧹 Invalidar caché", "invalidate_menu"),
        callback_button("👥 Administradores", "manage_admins"),
        callback_button("❓ Ayuda", "help")
    )
    return markup

def cloudfront_menu():
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        callback_button("🚀 Crear distribución", "create_cf"),
        callback_button("📋 Listar distribuciones", "list_dists"),
        callback_button("⚙️ Gestionar distribución", "manage_dists"),
        callback_button("🔙 Volver al inicio", "menu_principal")
    )
    return markup

def acm_menu():
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        callback_button("🔒 Solicitar certificado", "request_acm"),
        callback_button("📋 Listar certificados", "list_acm"),
        callback_button("🗑️ Eliminar certificado", "delete_acm"),
        callback_button("🔙 Volver al inicio", "menu_principal")
    )
    return markup

def admin_menu():
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        callback_button("➕ Agregar administrador", "add_admin"),
        callback_button("📋 Listar administradores", "list_admins"),
        callback_button("❌ Eliminar administrador", "remove_admin"),
        callback_button("🔙 Volver al inicio", "menu_principal")
    )
    return markup

def distribution_actions(distribution_id, distribution=None):
    markup = InlineKeyboardMarkup(row_width=1)
    markup.add(
        callback_button("✏️ Editar distribución", f"edit_dist_{distribution_id}"),
        callback_button("⏸️ Deshabilitar distribución", f"disable_dist_{distribution_id}"),
        callback_button("🧹 Invalidar caché", f"invalidate_dist_{distribution_id}")
    )

    if distribution:
        config = distribution.get("DistributionConfig", {})
        if not config.get("Enabled", True) and distribution.get("Status") == "Deployed":
            markup.add(callback_button("🗑️ Eliminar distribución", f"delete_dist_{distribution_id}"))

    markup.add(callback_button("🔙 Volver a la lista", "manage_dists"))
    return markup

# ============================================================
# COMANDOS
# ============================================================

@bot.message_handler(commands=["start", "menu", "help"])
def command_start(message):
    if not authorized_message(message):
        return

    chat_id = message.chat.id
    bot.send_message(
        chat_id,
        "⚙️ <b>PANEL DE CONTROL AWS</b>\nSelecciona una categoría:",
        reply_markup=main_menu(chat_id)
    )

@bot.message_handler(commands=["id"])
def command_id(message):
    user_id = message.from_user.id
    name = message.from_user.first_name or "Usuario"
    status = "✅ Administrador" if is_admin(user_id) else "❌ No autorizado"
    bot.reply_to(message, f"👤 {name}\n🆔 <code>{user_id}</code>\n{status}")

# ============================================================
# CALLBACKS
# ============================================================

@bot.callback_query_handler(func=lambda call: True)
def handle_callback(call):
    if not authorized_callback(call):
        return

    bot.answer_callback_query(call.id)
    chat_id = call.message.chat.id
    message_id = call.message.message_id
    action = call.data

    try:
        if action == "switch_account":
            current_profile = user_active_account.get(chat_id, "default")
            new_profile = "Superjabi" if current_profile == "default" else "default"
            user_active_account[chat_id] = new_profile
            
            account_name = "Principal" if new_profile == "default" else "Superjabi"
            bot.answer_callback_query(call.id, f"✅ Cuenta cambiada a: {account_name}")
            
            edit_message(
                chat_id,
                message_id,
                f"⚙️ <b>PANEL DE CONTROL AWS</b>\nHas seleccionado la cuenta: <b>{account_name}</b>\nSelecciona una categoría:",
                main_menu(chat_id)
            )

        elif action == "menu_principal":
            edit_message(chat_id, message_id, "⚙️ <b>PANEL DE CONTROL AWS</b>\nSelecciona una categoría:", main_menu(chat_id))

        elif action == "menu_cf":
            edit_message(chat_id, message_id, "🌐 <b>GESTIÓN DE CLOUDFRONT</b>\nSelecciona una opción:", cloudfront_menu())

        elif action == "menu_acm":
            edit_message(chat_id, message_id, "🔐 <b>GESTIÓN DE CERTIFICADOS ACM</b>", acm_menu())

        elif action == "create_cf":
            user_states[chat_id] = {"action": "create_cf", "step": "alias"}
            edit_message(chat_id, message_id, "🚀 <b>CREAR DISTRIBUCIÓN CLOUDFRONT</b>\n\nPaso 1/2: introduce el dominio personalizado.\nEjemplo: <code>cdn.ejemplo.com</code>")

        elif action == "list_dists":
            list_distributions(chat_id, message_id)

        elif action == "manage_dists":
            show_distribution_list(chat_id, message_id)

        elif action == "invalidate_menu":
            user_states[chat_id] = {"action": "invalidate", "step": "distribution_id"}
            edit_message(chat_id, message_id, "🧹 <b>INVALIDAR CACHÉ</b>\n\nIntroduce el ID de la distribución:\nEjemplo: <code>E1A2B3C4D5E6F7</code>")

        elif action.startswith("confirm_delete_dist_"):
            confirm_delete_distribution(chat_id, message_id, action[len("confirm_delete_dist_"):])

        elif action.startswith("delete_dist_"):
            delete_distribution(chat_id, message_id, action[len("delete_dist_"):])

        elif action.startswith("dist_"):
            show_distribution(chat_id, message_id, action[len("dist_"):])

        elif action.startswith("edit_dist_"):
            start_edit_distribution(chat_id, message_id, action[len("edit_dist_"):])

        elif action.startswith("disable_dist_"):
            disable_distribution(chat_id, message_id, action[len("disable_dist_"):])

        elif action.startswith("invalidate_dist_"):
            invalidate_distribution(chat_id, message_id, action[len("invalidate_dist_"):])

        elif action == "request_acm":
            user_states[chat_id] = {"action": "request_acm", "step": "domain"}
            edit_message(chat_id, message_id, "🔒 <b>SOLICITAR CERTIFICADO ACM</b>\n\nIntroduce el dominio:\nEjemplo: <code>cdn.ejemplo.com</code>")

        elif action == "list_acm":
            list_certificates(chat_id, message_id)

        elif action == "delete_acm":
            show_certificates_to_delete(chat_id, message_id)

        elif action.startswith("confirm_delete_cert_"):
            confirm_delete_certificate(chat_id, message_id, action[len("confirm_delete_cert_"):])

        elif action.startswith("delete_cert_"):
            delete_certificate(chat_id, message_id, action[len("delete_cert_"):])

        elif action == "manage_admins":
            edit_message(chat_id, message_id, "👥 <b>GESTIÓN DE ADMINISTRADORES</b>", admin_menu())

        elif action == "add_admin":
            if not is_super_admin(call.from_user.id):
                bot.send_message(chat_id, "⛔ Solo el superadministrador puede agregar admins.")
                return
            user_states[chat_id] = {"action": "add_admin", "step": "user_id"}
            edit_message(chat_id, message_id, "➕ <b>AGREGAR ADMINISTRADOR</b>\n\nEnvía el ID numérico del usuario.")

        elif action == "list_admins":
            list_admins(chat_id, message_id)

        elif action == "remove_admin":
            show_admins_to_remove(chat_id, message_id)

        elif action.startswith("remove_admin_"):
            remove_admin(chat_id, message_id, action[len("remove_admin_"):])

        elif action == "help":
            show_help(chat_id, message_id)

    except Exception as error:
        logger.exception("Error procesando callback")
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")


# ============================================================
# ENTRADA DE TEXTO
# ============================================================

@bot.message_handler(func=lambda message: is_admin(message.from_user.id))
def handle_text(message):
    chat_id = message.chat.id
    state = user_states.get(chat_id)

    if not state:
        return

    action = state.get("action")
    step = state.get("step")
    value = (message.text or "").strip()

    if action == "create_cf":
        handle_create_input(message, state, step, value, chat_id)

    elif action == "edit_cf":
        handle_edit_input(message, state, step, value, chat_id)

    elif action == "invalidate":
        if not valid_distribution_id(value):
            bot.reply_to(message, "⚠️ ID de distribución inválido.")
            return
        clear_state(chat_id)
        invalidation = create_invalidation(value, chat_id)
        bot.reply_to(message, f"✅ <b>Invalidación iniciada</b>\n\nDistribución: <code>{value}</code>\nID: <code>{invalidation}</code>")

    elif action == "request_acm":
        if not valid_domain(value):
            bot.reply_to(message, "⚠️ Dominio inválido.")
            return
        clear_state(chat_id)
        request_certificate(message, value, chat_id)

    elif action == "add_admin":
        if not value.isdigit():
            bot.reply_to(message, "⚠️ Debes enviar un ID numérico.")
            return
        user_id = int(value)
        if user_id in ADMIN_IDS:
            bot.reply_to(message, "⚠️ Ese usuario ya es administrador.")
        else:
            ADMIN_IDS.append(user_id)
            save_admins()
            bot.reply_to(message, f"✅ Administrador agregado: <code>{user_id}</code>")
        clear_state(chat_id)


# ============================================================
# CREAR DISTRIBUCIÓN
# ============================================================

def handle_create_input(message, state, step, value, chat_id):
    if step == "alias":
        if not valid_domain(value):
            bot.reply_to(message, "⚠️ Dominio inválido.")
            return
        state["alias"] = value
        state["step"] = "origin"
        bot.reply_to(message, "✅ Alias guardado.\n\nPaso 2/2: introduce el dominio del origen (tu VPS).\nEjemplo: <code>origen.ejemplo.com</code>")

    elif step == "origin":
        if not value or " " in value:
            bot.reply_to(message, "⚠️ Origen inválido.")
            return

        alias = state["alias"]
        origin = value
        msg = bot.reply_to(message, "⏳ Buscando el certificado en ACM y creando distribución...")
        
        cert_arn = get_acm_arn_for_domain(alias, chat_id)
        if not cert_arn:
            bot.edit_message_text(
                f"❌ <b>Error:</b> No se encontró un certificado ACM emitido para <code>{alias}</code>.\n\nAsegúrate de haberlo solicitado y que esté 'ISSUED'.",
                chat_id=chat_id, message_id=msg.message_id, parse_mode="HTML"
            )
            clear_state(chat_id)
            return

        try:
            cf = get_cf(chat_id)
            response = cf.create_distribution(
                DistributionConfig=build_distribution_config(alias, origin, cert_arn)
            )
            distribution = response["Distribution"]
            clear_state(chat_id)
            bot.edit_message_text(
                "✅ <b>DISTRIBUCIÓN CREADA</b>\n\n"
                f"🆔 ID: <code>{distribution['Id']}</code>\n"
                f"🌐 Dominio CloudFront: <code>{distribution['DomainName']}</code>\n"
                f"🎯 Origen: <code>{origin}</code>\n"
                f"📊 Estado: <code>{distribution['Status']}</code>",
                chat_id=chat_id, message_id=msg.message_id, parse_mode="HTML"
            )
        except Exception as error:
            bot.edit_message_text(f"❌ <b>Error:</b> {safe_error(error)}", chat_id=chat_id, message_id=msg.message_id, parse_mode="HTML")

def build_distribution_config(alias, origin, certificate_arn):
    return {
        "CallerReference": f"telegram-{time.time_ns()}",
        "Aliases": {"Quantity": 1, "Items": [alias]},
        "Origins": {
            "Quantity": 1,
            "Items": [{
                "Id": "origin-1",
                "DomainName": origin,
                "CustomOriginConfig": {
                    "HTTPPort": 80, "HTTPSPort": 443,
                    "OriginProtocolPolicy": "match-viewer",
                    "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
                    "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 60
                }
            }]
        },
        "DefaultCacheBehavior": {
            "TargetOriginId": "origin-1",
            "ViewerProtocolPolicy": "allow-all",
            "AllowedMethods": {
                "Quantity": 7, "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
                "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
            },
            "ForwardedValues": {
                "QueryString": True, "Cookies": {"Forward": "all"},
                "Headers": {"Quantity": 1, "Items": ["Host"]}
            },
            "TrustedSigners": {"Enabled": False, "Quantity": 0},
            "GrpcConfig": {"Enabled": True},
            "MinTTL": 0, "DefaultTTL": 0, "MaxTTL": 0
        },
        "Comment": f"Managed by Telegram - {alias}",
        "Enabled": True,
        "ViewerCertificate": {
            "ACMCertificateArn": certificate_arn,
            "SSLSupportMethod": "sni-only",
            "MinimumProtocolVersion": "TLSv1.2_2021"
        },
        "HttpVersion": "http2and3",
        "PriceClass": "PriceClass_100"
    }

# ============================================================
# EDITAR DISTRIBUCIÓN
# ============================================================

def start_edit_distribution(chat_id, message_id, distribution_id):
    try:
        response = get_distribution(distribution_id, chat_id)
        distribution = response["Distribution"]
        config = distribution["DistributionConfig"]
        aliases = config.get("Aliases", {}).get("Items", [])
        origins = config.get("Origins", {}).get("Items", [])
        alias = aliases[0] if aliases else ""
        origin = origins[0].get("DomainName", "") if origins else ""

        user_states[chat_id] = {
            "action": "edit_cf", "step": "alias", "distribution_id": distribution_id,
            "etag": response["ETag"], "config": config, "alias": alias, "origin": origin
        }

        edit_message(
            chat_id, message_id,
            f"✏️ <b>EDITAR DISTRIBUCIÓN</b>\n\nID: <code>{distribution_id}</code>\n\nAlias actual: <code>{alias or 'Sin alias'}</code>\nEnvía el nuevo alias o escribe <code>-</code> para conservarlo."
        )
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")

def handle_edit_input(message, state, step, value, chat_id):
    if value == "-":
        value = state.get(step, "")

    if step == "alias":
        if value and not valid_domain(value):
            bot.reply_to(message, "⚠️ Alias inválido.")
            return
        state["alias"] = value
        state["step"] = "origin"
        bot.reply_to(message, f"✅ Alias: <code>{value or 'Sin alias'}</code>\n\nOrigen actual: <code>{state['origin']}</code>\nEnvía el nuevo origen o <code>-</code> para conservarlo.")

    elif step == "origin":
        if not value or " " in value:
            bot.reply_to(message, "⚠️ Origen inválido.")
            return
        state["origin"] = value
        
        cert_arn = get_acm_arn_for_domain(state["alias"], chat_id)
        if not cert_arn:
            bot.reply_to(message, f"❌ No se encontró un certificado ACM para <code>{state['alias']}</code>.")
            clear_state(chat_id)
            return
            
        state["certificate_arn"] = cert_arn
        markup = InlineKeyboardMarkup(row_width=2)
        markup.add(
            callback_button("✅ Confirmar", f"confirm_edit_{chat_id}"),
            callback_button("❌ Cancelar", f"cancel_edit_{chat_id}")
        )
        bot.reply_to(
            message,
            f"⚠️ <b>CONFIRMA LOS CAMBIOS</b>\n\nAlias: <code>{state['alias'] or 'Sin alias'}</code>\nOrigen: <code>{state['origin']}</code>\nCertificado: <code>...{cert_arn[-15:]}</code>",
            reply_markup=markup
        )

@bot.callback_query_handler(func=lambda call: call.data.startswith("confirm_edit_"))
def confirm_edit_callback(call):
    if not authorized_callback(call): return
    chat_id = call.message.chat.id
    state = user_states.get(chat_id)
    if not state or state.get("action") != "edit_cf":
        bot.answer_callback_query(call.id, "La sesión expiró.", show_alert=True)
        return

    bot.answer_callback_query(call.id)
    try:
        config = state["config"]
        config["Aliases"] = {"Quantity": 1 if state["alias"] else 0, "Items": [state["alias"]] if state["alias"] else []}
        if config.get("Origins", {}).get("Items"):
            config["Origins"]["Items"][0]["DomainName"] = state["origin"]
            if "CustomOriginConfig" in config["Origins"]["Items"][0]:
                config["Origins"]["Items"][0]["CustomOriginConfig"]["OriginProtocolPolicy"] = "match-viewer"

        config["ViewerCertificate"] = {
            "ACMCertificateArn": state["certificate_arn"],
            "SSLSupportMethod": "sni-only", "MinimumProtocolVersion": "TLSv1.2_2021"
        }
        if "DefaultCacheBehavior" in config:
            config["DefaultCacheBehavior"]["GrpcConfig"] = {"Enabled": True}
        config["HttpVersion"] = "http2and3"
        config["Comment"] = f"Managed by Telegram - {state['alias']}"

        get_cf(chat_id).update_distribution(Id=state["distribution_id"], IfMatch=state["etag"], DistributionConfig=config)
        clear_state(chat_id)
        edit_message(chat_id, call.message.message_id, "✅ <b>DISTRIBUCIÓN ACTUALIZADA</b>\n\n⏳ AWS está desplegando los cambios.", back_button("manage_dists"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error al actualizar:</b> {safe_error(error)}")

@bot.callback_query_handler(func=lambda call: call.data.startswith("cancel_edit_"))
def cancel_edit_callback(call):
    if not authorized_callback(call): return
    chat_id = call.message.chat.id
    clear_state(chat_id)
    bot.answer_callback_query(call.id, "Edición cancelada.")
    edit_message(chat_id, call.message.message_id, "❌ Edición cancelada.", back_button("manage_dists"))


# ============================================================
# CLOUDFRONT 
# ============================================================

def list_distributions(chat_id, message_id):
    try:
        items = get_cf(chat_id).list_distributions().get("DistributionList", {}).get("Items", [])
        if not items:
            edit_message(chat_id, message_id, "📭 No hay distribuciones CloudFront en esta cuenta.", back_button("menu_cf"))
            return

        text = f"📋 <b>DISTRIBUCIONES ({len(items)})</b>\n\n"
        
        # Usamos enumerate(..., start=1) para numerar la lista automáticamente
        for i, item in enumerate(items, start=1):
            # Extraer el alias (dominio personalizado / de Cloudflare)
            aliases = item.get("Aliases", {}).get("Items", [])
            alias_str = ", ".join(aliases) if aliases else "Sin alias"
            
            text += (
                f"<b>{i}.</b> 🆔 <code>{item['Id']}</code>\n"
                f"🏷️ <code>{alias_str}</code>\n"
                f"🌐 <code>{item['DomainName']}</code>\n"
                f"📊 {item['Status']}\n"
                f"🔌 {'✅ Activa' if item['Enabled'] else '❌ Deshabilitada'}\n"
                f"🟩=========================🟩\n\n"
            )
            
        edit_message(chat_id, message_id, text, back_button("menu_cf"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")

def show_distribution_list(chat_id, message_id):
    try:
        items = get_cf(chat_id).list_distributions().get("DistributionList", {}).get("Items", [])
        if not items:
            edit_message(chat_id, message_id, "📭 No hay distribuciones para gestionar.", back_button("menu_cf"))
            return

        markup = InlineKeyboardMarkup(row_width=1)
        for item in items[:20]:
            icon = "🟢" if item["Status"] == "Deployed" else "🟡"
            markup.add(callback_button(f"{icon} {distribution_name(item)}", f"dist_{item['Id']}"))
        markup.add(callback_button("🔙 Volver", "menu_cf"))
        edit_message(chat_id, message_id, "⚙️ <b>SELECCIONA UNA DISTRIBUCIÓN</b>", markup)
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")

def show_distribution(chat_id, message_id, distribution_id):
    try:
        response = get_distribution(distribution_id, chat_id)
        distribution = response["Distribution"]
        config = distribution["DistributionConfig"]
        aliases = config.get("Aliases", {}).get("Items", [])
        origins = config.get("Origins", {}).get("Items", [])
        origin = origins[0].get("DomainName", "N/A") if origins else "N/A"

        text = f"⚙️ <b>DETALLE DE DISTRIBUCIÓN</b>\n\n🆔 ID: <code>{distribution['Id']}</code>\n🌐 CloudFront: <code>{distribution['DomainName']}</code>\n🏷️ Alias: <code>{', '.join(aliases) or 'Sin alias'}</code>\n🎯 Origen: <code>{origin}</code>\n📊 Estado: <code>{distribution['Status']}</code>\n🔌 Habilitada: {'✅ Sí' if config['Enabled'] else '❌ No'}"
        edit_message(chat_id, message_id, text, distribution_actions(distribution_id, distribution))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")

def disable_distribution(chat_id, message_id, distribution_id):
    try:
        cf = get_cf(chat_id)
        response = cf.get_distribution_config(Id=distribution_id)
        config = response["DistributionConfig"]
        config["Enabled"] = False
        cf.update_distribution(Id=distribution_id, IfMatch=response["ETag"], DistributionConfig=config)

        edit_message(chat_id, message_id, f"✅ <b>DISTRIBUCIÓN DESHABILITADA</b>\n\nID: <code>{distribution_id}</code>\n⏳ Espera a que el estado sea <code>Deployed</code> para eliminarla.", back_button("manage_dists"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")

def delete_distribution(chat_id, message_id, distribution_id):
    try:
        response = get_distribution(distribution_id, chat_id)
        distribution = response["Distribution"]
        config = distribution["DistributionConfig"]

        if config.get("Enabled", True):
            edit_message(chat_id, message_id, "⚠️ La distribución todavía está habilitada.\nDeshabilítala primero.", back_button(f"dist_{distribution_id}"))
            return

        if distribution.get("Status") != "Deployed":
            edit_message(chat_id, message_id, "⏳ La distribución todavía está desplegándose.\nEspera hasta que su estado sea <code>Deployed</code>.", back_button(f"dist_{distribution_id}"))
            return

        markup = InlineKeyboardMarkup(row_width=2)
        markup.add(callback_button("✅ Confirmar eliminación", f"confirm_delete_dist_{distribution_id}"), callback_button("❌ Cancelar", f"dist_{distribution_id}"))
        edit_message(chat_id, message_id, f"⚠️ <b>CONFIRMAR ELIMINACIÓN</b>\n\nID: <code>{distribution_id}</code>\n\nEsta acción no se puede deshacer.", markup)
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")

def confirm_delete_distribution(chat_id, message_id, distribution_id):
    try:
        response = get_distribution(distribution_id, chat_id)
        if response["Distribution"]["DistributionConfig"].get("Enabled", True):
            bot.send_message(chat_id, "❌ La distribución debe estar deshabilitada.")
            return
        
        get_cf(chat_id).delete_distribution(Id=distribution_id, IfMatch=response["ETag"])
        edit_message(chat_id, message_id, f"✅ <b>DISTRIBUCIÓN ELIMINADA</b>\n\nID: <code>{distribution_id}</code>", back_button("manage_dists"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error al eliminar:</b> {safe_error(error)}")

def create_invalidation(distribution_id, chat_id):
    response = get_cf(chat_id).create_invalidation(
        DistributionId=distribution_id,
        InvalidationBatch={"Paths": {"Quantity": 1, "Items": ["/*"]}, "CallerReference": f"telegram-{time.time_ns()}"}
    )
    return response["Invalidation"]["Id"]

def invalidate_distribution(chat_id, message_id, distribution_id):
    try:
        invalidation_id = create_invalidation(distribution_id, chat_id)
        edit_message(chat_id, message_id, f"✅ <b>INVALIDACIÓN INICIADA</b>\n\nDistribución: <code>{distribution_id}</code>\nInvalidación: <code>{invalidation_id}</code>", back_button("manage_dists"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error:</b> {safe_error(error)}")


# ============================================================
# ACM
# ============================================================

def request_certificate(message, domain, chat_id):
    try:
        response = get_acm(chat_id).request_certificate(DomainName=domain, ValidationMethod="DNS")
        bot.reply_to(message, f"✅ <b>Certificado solicitado</b>\n\nDominio: <code>{domain}</code>\nARN: <code>{response['CertificateArn']}</code>\n\nAñade el registro CNAME de validación DNS que aparece en ACM.")
    except Exception as error:
        bot.reply_to(message, f"❌ <b>Error ACM:</b> {safe_error(error)}")

def list_certificates(chat_id, message_id):
    try:
        response = get_acm(chat_id).list_certificates(CertificateStatuses=["ISSUED", "PENDING_VALIDATION", "FAILED", "VALIDATION_TIMED_OUT"])
        certificates = response.get("CertificateSummaryList", [])
        if not certificates:
            edit_message(chat_id, message_id, "📭 No hay certificados ACM.", back_button("menu_acm"))
            return

        text = "🔐 <b>CERTIFICADOS ACM</b>\n\n"
        for cert in certificates[:30]:
            text += f"🌐 <b>{cert.get('DomainName', 'N/A')}</b>\n📊 {cert.get('Status', 'N/A')}\n🔑 <code>{cert['CertificateArn']}</code>\n\n"
        edit_message(chat_id, message_id, text, back_button("menu_acm"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error ACM:</b> {safe_error(error)}")

def show_certificates_to_delete(chat_id, message_id):
    try:
        response = get_acm(chat_id).list_certificates(CertificateStatuses=["ISSUED", "PENDING_VALIDATION", "FAILED", "VALIDATION_TIMED_OUT"])
        certificates = response.get("CertificateSummaryList", [])[:30]
        if not certificates:
            edit_message(chat_id, message_id, "📭 No hay certificados ACM para eliminar.", back_button("menu_acm"))
            return

        user_states[chat_id] = {"action": "delete_acm", "certificates": {str(i): c["CertificateArn"] for i, c in enumerate(certificates)}}
        markup = InlineKeyboardMarkup(row_width=1)
        for i, c in enumerate(certificates):
            markup.add(callback_button(f"🗑️ {c.get('DomainName', 'Sin dominio')} ({c.get('Status', 'N/A')})"[:64], f"delete_cert_{i}"))
        markup.add(callback_button("🔙 Volver", "menu_acm"))
        edit_message(chat_id, message_id, "🗑️ <b>SELECCIONA EL CERTIFICADO A ELIMINAR</b>", markup)
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>Error ACM:</b> {safe_error(error)}")

def delete_certificate(chat_id, message_id, certificate_index):
    state = user_states.get(chat_id, {})
    cert_arn = state.get("certificates", {}).get(str(certificate_index))
    if not cert_arn:
        bot.answer_callback_query(str(chat_id), "La selección expiró. Vuelve a abrir el menú.", show_alert=True)
        return

    state["selected_certificate"] = cert_arn
    markup = InlineKeyboardMarkup(row_width=2)
    markup.add(callback_button("✅ Confirmar eliminación", f"confirm_delete_cert_{certificate_index}"), callback_button("❌ Cancelar", "delete_acm"))
    edit_message(chat_id, message_id, f"⚠️ <b>CONFIRMAR ELIMINACIÓN DEL CERTIFICADO</b>\n\n<code>{cert_arn}</code>", markup)

def confirm_delete_certificate(chat_id, message_id, certificate_index):
    cert_arn = user_states.get(chat_id, {}).get("selected_certificate")
    if not cert_arn:
        bot.send_message(chat_id, "❌ La selección expiró.")
        return
    try:
        get_acm(chat_id).delete_certificate(CertificateArn=cert_arn)
        clear_state(chat_id)
        edit_message(chat_id, message_id, f"✅ <b>CERTIFICADO ELIMINADO</b>\n\n<code>{cert_arn}</code>", back_button("menu_acm"))
    except Exception as error:
        bot.send_message(chat_id, f"❌ <b>No se pudo eliminar:</b>\n{safe_error(error)}")

# ============================================================
# ADMINISTRADORES Y AYUDA
# ============================================================

def list_admins(chat_id, message_id):
    text = "📋 <b>ADMINISTRADORES</b>\n\n"
    for index, admin_id in enumerate(ADMIN_IDS, 1):
        text += f"{index}. <code>{admin_id}</code>\n"
    edit_message(chat_id, message_id, f"{text}\nTotal: <b>{len(ADMIN_IDS)}</b>", back_button("manage_admins"))

def show_admins_to_remove(chat_id, message_id):
    if not is_super_admin(chat_id):
        bot.send_message(chat_id, "⛔ Solo el superadministrador puede eliminar admins.")
        return
    removable = [a for a in ADMIN_IDS if a != INITIAL_ADMIN_ID]
    if not removable:
        edit_message(chat_id, message_id, "⚠️ No hay administradores secundarios para eliminar.", back_button("manage_admins"))
        return

    markup = InlineKeyboardMarkup(row_width=1)
    for admin_id in removable:
        markup.add(callback_button(f"❌ Eliminar {admin_id}", f"remove_admin_{admin_id}"))
    markup.add(callback_button("🔙 Cancelar", "manage_admins"))
    edit_message(chat_id, message_id, "Selecciona el administrador a eliminar:", markup)

def remove_admin(chat_id, message_id, admin_id):
    if not is_super_admin(chat_id):
        bot.send_message(chat_id, "⛔ Operación no permitida.")
        return
    try:
        admin_id = int(admin_id)
    except ValueError:
        bot.send_message(chat_id, "❌ ID inválido.")
        return

    if admin_id in ADMIN_IDS and admin_id != INITIAL_ADMIN_ID:
        ADMIN_IDS.remove(admin_id)
        save_admins()
    edit_message(chat_id, message_id, f"✅ Administrador <code>{admin_id}</code> eliminado.", back_button("manage_admins"))

def show_help(chat_id, message_id):
    text = (
        "📚 <b>AYUDA DEL SISTEMA</b>\n\n"
        "🌐 <b>CloudFront:</b> crea, lista, edita, deshabilita y elimina distribuciones.\n"
        "🔐 <b>ACM:</b> solicita, lista y elimina certificados.\n"
        "👥 <b>Administradores:</b> controla el acceso al bot.\n"
        "🔄 <b>Cuentas:</b> usa el botón del menú para cambiar entre cuentas AWS.\n\n"
        "<b>Comandos:</b>\n/start - Abrir el menú\n/id - Mostrar tu ID"
    )
    edit_message(chat_id, message_id, text, main_menu(chat_id))

def edit_message(chat_id, message_id, text, markup=None):
    bot.edit_message_text(text, chat_id=chat_id, message_id=message_id, reply_markup=markup)

# ============================================================
# ARRANQUE
# ============================================================

if __name__ == "__main__":
    logger.info("Bot AWS iniciado correctamente.")
    bot.infinity_polling(skip_pending=True)

