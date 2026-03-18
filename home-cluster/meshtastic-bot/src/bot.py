import os
import logging
import time
import json

import meshtastic
from meshtastic import tcp_interface
from meshtastic import mesh_pb2
import paho.mqtt.client as mqtt
import requests

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

MESHMONITOR_HOST = os.getenv('MESHMONITOR_HOST', 'meshmonitor.meshtastic.svc.cluster.local')
MESHMONITOR_PORT = int(os.getenv('MESHMONITOR_PORT', '4404'))

MESHMONITOR_API_URL = os.getenv('MESHMONITOR_URL', 'http://meshmonitor.meshtastic.svc.cluster.local:3001')
MESHMONITOR_TOKEN = os.getenv('MESHMONITOR_TOKEN', '')

MQTT_ADDRESS = os.getenv('MQTT_ADDRESS', 'mosquitto.mqtt.svc.cluster.local')
MQTT_PORT = int(os.getenv('MQTT_PORT', '1883'))
MQTT_TOPIC_PREFIX = os.getenv('MQTT_TOPIC_PREFIX', 'msh/US/bayarea')

BOT_NODE_NUM = int(os.getenv('BOT_NODE_NUM', '1770369408'))
BOT_ALIAS = os.getenv('BOT_ALIAS', 'hotpotato').lower()
HOP_LIMIT = int(os.getenv('HOP_LIMIT', '7'))

TEST_CHANNELS = os.getenv('TEST_CHANNELS', 'MeshChat,MediumFast').split(',')

PREFIX = f"/{BOT_ALIAS}"
AT_PREFIX = f"@{BOT_ALIAS}"

CHANNELS = {
    'MediumFast': {'name': 'MediumFast', 'psk': 'AQ=='},
    'Test': {'name': 'Test', 'psk': 'TQ=='},
    'Alerts': {'name': 'Alerts', 'psk': 'AQ=='},
    'Ham': {'name': 'Ham', 'psk': 'CQ=='},
    'MeshQuake': {'name': 'MeshQuake', 'psk': 'EQ=='},
    'BayMeshNews': {'name': 'BayMeshNews', 'psk': '5g=='},
    'SF': {'name': 'SF', 'psk': 'SA=='},
}

COMMANDS = f"""Commands:
{AT_PREFIX} channels - channel list
{AT_PREFIX} trace - hops from base
{AT_PREFIX} test - bot status
{AT_PREFIX} net - weekly net info
{AT_PREFIX} help - list commands""" #\n{AT_PREFIX} online - node count

interface = None
mqtt_client = None


def get_active_node_count(hours: int = 24) -> int:
    """Get count of nodes active in the last N hours from MeshMonitor API."""
    try:
        url = f"{MESHMONITOR_API_URL}/api/nodes"
        # Try without auth first, then with
        for use_auth in [False, True]:
            headers = {}
            if use_auth and MESHMONITOR_TOKEN:
                headers['Authorization'] = f'Bearer {MESHMONITOR_TOKEN}'
            response = requests.get(url, headers=headers, timeout=10)
            logger.info(f"/api/nodes (auth={use_auth}) status: {response.status_code}, body: {response.text[:200]}")
            if response.status_code == 200:
                data = response.json()
                if isinstance(data, dict):
                    nodes = data.get('nodes', [])
                else:
                    nodes = data
                if len(nodes) > 0:
                    return len(nodes)
        return 0
    except Exception as e:
        logger.error(f"Failed to get active nodes: {e}")
        return -1


def get_hops_away(from_node: int) -> int:
    """Get hops away for a specific node from meshmonitor API. Not used - using MQTT hops_away instead."""
    return -1


def format_channels_list() -> str:
    """Format the channels list as a response."""
    lines = []
    for key, ch in CHANNELS.items():
        lines.append(f"{ch['name']}: {ch['psk']}")
    return "\n".join(lines[:8])


def handle_command(command: str, from_node: int, from_id: str, hops_away: int = -1) -> str:
    """Handle a bot command and return response text."""
    cmd = command.strip().lower()

    # online
    if cmd == f"{PREFIX} online" or cmd == f"{AT_PREFIX} online":
        count = get_active_node_count(24)
        if count >= 0:
            return f"Nodes active in last 24h: {count}"
        return "Error: Could not fetch node count"
    # trace
    elif cmd == f"{PREFIX} trace" or cmd == f"{AT_PREFIX} trace":
        if hops_away >= 0:
            return f"Your node is {hops_away} hop(s) away from Clayton, CA"
        return "Could not determine hop count"
    # channels
    elif cmd == f"{PREFIX} channels" or cmd == f"{AT_PREFIX} channels":
        return format_channels_list()
    # test
    elif cmd == f"{PREFIX} test" or cmd == f"{AT_PREFIX} test":
        return f"HotPotato Bot is online! 🥔🤖"
    # net
    elif cmd == f"{PREFIX} net" or cmd == f"{AT_PREFIX} net":
        return "Weekly Net: Wednesdays 5pm PST on MediumFast\nFormat: (LONG NAME) - (CITY) #BayMeshNet"
    # help/commands
    elif cmd in (f"{PREFIX} commands", f"{AT_PREFIX} commands", f"{PREFIX} help", f"{AT_PREFIX} help", f"{PREFIX}", AT_PREFIX):
        return COMMANDS
    # else:
    #     return f"Unknown command: {command}. Try {PREFIX} help"


def send_text(text: str, channel_index: int = 0):
    """Send a text message via Meshtastic TCP interface."""
    try:
        interface.sendData(text.encode('utf-8'), channelIndex=channel_index, portNum=1, hopLimit=HOP_LIMIT)
        logger.info(f"Sent: {text[:50]}...")
    except Exception as e:
        logger.error(f"Failed to send message: {e}")


def send_emoji(emoji: str, channel_index: int = 0, reply_id: int = None):
    """Send an emoji reaction via Meshtastic TCP interface."""
    try:
        if interface is None:
            logger.error("Interface is None, cannot send emoji")
            return
        logger.info(f"Sending emoji '{emoji}' on channel {channel_index} with reply_id={reply_id}")
        if reply_id is not None:
            data = mesh_pb2.Data()
            data.payload = emoji.encode('utf-8')
            data.emoji = 1
            interface.sendData(data, channelIndex=channel_index, replyId=reply_id, hopLimit=HOP_LIMIT, wantAck=True)
        else:
            interface.sendData(emoji.encode('utf-8'), channelIndex=channel_index, hopLimit=HOP_LIMIT, wantAck=True)
        logger.info(f"Sent emoji: {emoji}")
    except Exception as e:
        logger.error(f"Failed to send emoji: {e}")


def on_mqtt_message(client, userdata, msg):
    """Handle incoming MQTT message."""
    try:
        payload = json.loads(msg.payload.decode())
    except (json.JSONDecodeError, UnicodeDecodeError):
        return

    topic_parts = msg.topic.split('/')
    try:
        channel_name = topic_parts[5] if len(topic_parts) > 5 else None
    except Exception as e:
        logger.error(f"Failed to get channel name: {e}")
        channel_name = None

    msg_type = payload.get('type', '')
    if msg_type != 'text':
        return

    text = payload.get('payload', {}).get('text', '')
    from_node = payload.get('from')
    sender_id = payload.get('sender', '')
    channel = payload.get('channel', 0)
    message_id = payload.get('id')

    hops_away = payload.get('hops_away', -1)

    logger.info(f"MQTT received from {sender_id}: {text} (channel={channel}, channel_name={channel_name}, hops_away={hops_away})")

    if from_node == BOT_NODE_NUM:
        return

    # Check for "test" in message on configured channels - send numeric emoji tapback based on hops
    # Only send emoji if it's NOT a command (not starting with / or @)
    logger.info(f"Checking test: text='{text}', channel_name='{channel_name}', TEST_CHANNELS={TEST_CHANNELS}")
    if 'test' in text.lower() and channel_name in TEST_CHANNELS and not text.startswith('/') and not text.startswith('@'):
        logger.info(f"Sending emoji for 'test' on channel {channel_name}, hops_away={hops_away}")
        try:
            if hops_away == 0:
                emoji = "*️⃣"
                send_emoji(emoji, channel_index=channel, reply_id=message_id)
            elif hops_away > 0:
                emoji = str(hops_away) + "️⃣"
                send_emoji(emoji, channel_index=channel, reply_id=message_id)
        except Exception as e:
            logger.error(f"Error sending emoji: {e}")

    if text.startswith('/') or text.startswith('@'):
        try:
            response = handle_command(text, from_node, sender_id, hops_away)
            send_text(response, channel_index=channel)
        except Exception as e:
            logger.error(f"Error handling command: {e}")


def on_mqtt_connect(client, userdata, flags, rc):
    if rc == 0:
        logger.info("MQTT connected successfully")
        client.subscribe(f"{MQTT_TOPIC_PREFIX}/#")
    else:
        logger.error(f"MQTT connection failed with code {rc}")


def run_mqtt():
    """Run MQTT client."""
    global mqtt_client
    mqtt_client = mqtt.Client()
    mqtt_client.on_connect = on_mqtt_connect
    mqtt_client.on_message = on_mqtt_message
    
    try:
        mqtt_client.connect(MQTT_ADDRESS, MQTT_PORT, 60)
        logger.info(f"MQTT connecting to {MQTT_ADDRESS}:{MQTT_PORT}...")
        mqtt_client.loop_forever()
    except Exception as e:
        logger.error(f"MQTT error: {e}")


def on_connection(interface, topic):
    logger.info("TCP connected to MeshMonitor!")


def on_connection_lost(interface, topic):
    logger.warning("TCP connection lost, will reconnect...")


def main():
    """Main entry point."""
    global interface

    from pubsub import pub
    pub.subscribe(on_connection, "meshtastic.connection.established")
    pub.subscribe(on_connection_lost, "meshtastic.connection.lost")

    import threading
    mqtt_thread = threading.Thread(target=run_mqtt, daemon=True)
    mqtt_thread.start()

    logger.info(f"Starting bot. TCP: {MESHMONITOR_HOST}:{MESHMONITOR_PORT}, MQTT: {MQTT_ADDRESS}")

    while True:
        try:
            logger.info(f"Connecting to Meshtastic via TCP...")
            interface = tcp_interface.TCPInterface(hostname=MESHMONITOR_HOST, portNumber=MESHMONITOR_PORT, connectNow=True)
            logger.info("TCP connected, waiting for MQTT commands...")
            while True:
                time.sleep(10)
        except KeyboardInterrupt:
            break
        except Exception as e:
            logger.error(f"TCP connection failed: {e}, retrying in 5s...")
            time.sleep(5)


if __name__ == "__main__":
    main()
