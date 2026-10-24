import json
import time
import urllib.request

# --- CONFIGURATION ---
HETZNER_API_TOKEN = (
    "3x7d3e5QyHe3fpw3twOaUlvBVG1aMFyudxoO595qFie9jvLTzo0clXJCxXxR7HUb"
)
TELEGRAM_BOT_TOKEN = "8975853738:AAEIi7nSsZBNotZieoMVxRbFLerLsrppgTc"
TELEGRAM_CHAT_ID = "8888601891"

HETZNER_URL = "https://api.hetzner.cloud/v1/server_types"
BUYVM_URL = "https://my.frantech.ca/cart.php?a=add&pid=1463"
# ---------------------

def send_telegram_alert(message):
  tg_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
  payload = json.dumps({"chat_id": TELEGRAM_CHAT_ID, "text": message}).encode(
      "utf-8"
  )
  req = urllib.request.Request(
      tg_url, data=payload, headers={"Content-Type": "application/json"}
  )
  try:
    urllib.request.urlopen(req)
  except Exception as e:
    print(f"Failed to send Telegram alert: {e}")

def check_hetzner(alerted_set):
  headers = {
      "Authorization": f"Bearer {HETZNER_API_TOKEN}",
      "User-Agent": "Mozilla/5.0",
  }
  req = urllib.request.Request(HETZNER_URL, headers=headers)
  try:
    with urllib.request.urlopen(req) as response:
      if response.status != 200:
        print(f"Hetzner Error: Status {response.status}")
        return False
      data = json.loads(response.read().decode("utf-8"))
  except Exception as e:
    print(f"Hetzner Network error: {e}")
    return False

  currently_available = set()

  for stype in data.get("server_types", []):
    name = stype["name"]
    if name.startswith("cx") or name.startswith("cax"):
      for price_entry in stype.get("prices", []):
        loc = price_entry.get("location")
        if loc in ["hil1", "ash1"]:
          unavailable_locs = stype.get("unavailable_locations", [])
          if loc not in unavailable_locs:
            item_key = f"{name}-{loc}"
            currently_available.add(item_key)

            # Only alert if we haven't already for this specific server/location
            if item_key not in alerted_set:
              alert_msg = (
                  f"🚨 HETZNER ALERT! Server {name} is NOW AVAILABLE in"
                  f" {loc.upper()}! Go grab it!"
              )
              print(alert_msg)
              send_telegram_alert(alert_msg)
              alerted_set.add(item_key)

  # Reset memory for items that went back out of stock
  for item in list(alerted_set):
    if item not in currently_available:
      alerted_set.remove(item)

  return len(currently_available) > 0

def check_buyvm(already_alerted):
  headers = {
      "User-Agent": (
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
          " (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"
      )
  }
  req = urllib.request.Request(BUYVM_URL, headers=headers)
  is_available = False
  
  try:
    with urllib.request.urlopen(req) as response:
      if response.status != 200:
        print(f"BuyVM Error: Status {response.status}")
        return False, already_alerted
      
      html = response.read().decode("utf-8", errors="ignore")

      if "Out of Stock" not in html:
        is_available = True
        
        # Only alert if we haven't already
        if not already_alerted:
          alert_msg = (
              "🚨 BUYVM ALERT! Las Vegas 1TB Storage Slab is IN STOCK! Go to:"
              f" {BUYVM_URL}"
          )
          print(alert_msg)
          send_telegram_alert(alert_msg)
          already_alerted = True
      else:
        # Reset memory if it goes out of stock again
        already_alerted = False

  except urllib.error.HTTPError as e:
    print(f"BuyVM Network Blocked (Cloudflare): {e.code}")
  except Exception as e:
    print(f"BuyVM Network error: {e}")

  return is_available, already_alerted

if __name__ == "__main__":
  print("Starting Unified Stock Watcher (Anti-Spam Edition)...")
  
  # Initialize empty memories
  active_hetzner_alerts = set()
  buyvm_alerted = False
  
  while True:
    hetzner_in_stock = check_hetzner(active_hetzner_alerts)
    buyvm_in_stock, buyvm_alerted = check_buyvm(buyvm_alerted)

    if not hetzner_in_stock and not buyvm_in_stock:
      print(
          f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Budget servers and BuyVM 1TB"
          " Slabs still out of stock. Checking again in 60s..."
      )
    else:
      print(
          f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Stock detected! (Alerts already"
          " sent). Keeping quiet and checking again in 60s..."
      )

    time.sleep(60)