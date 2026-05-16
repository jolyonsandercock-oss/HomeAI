# WhatsApp Web pairing — one-time setup per account

WhatsApp Web needs a QR scan from your phone to attach the browser session. We do this once per account (`personal`, `pub`); the persistent profile dir keeps the session alive for ~14 days of inactivity (longer if regularly used).

## Pre-flight

- The phone running the WhatsApp account must be online when you scan, and stay online occasionally (~once every 14 days) thereafter.
- WhatsApp Web only allows **4 linked devices per account**. If you already have desktop + web sessions, remove one before pairing.

## Pairing steps (personal account)

```bash
# 1. Stop the headless service so we can run a one-shot headed browser
docker compose stop wa-bridge

# 2. Run a headed Playwright session bound to the persistent profile
docker run --rm -it \
  --network home_ai_ai-egress \
  -v /home_ai/data/wa-profiles/personal:/profile \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  mcr.microsoft.com/playwright/python:v1.45.0-jammy \
  python3 -c "
from playwright.sync_api import sync_playwright
import time
with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context('/profile', headless=False)
    page = ctx.new_page()
    page.goto('https://web.whatsapp.com')
    print('Scan the QR with the phone. Browser stays open 5 minutes.')
    time.sleep(300)
    ctx.close()
"

# 3. Restart the headless bridge
docker compose start wa-bridge

# 4. Verify pairing worked
curl -s http://localhost:8770/accounts/personal/scrape | python3 -m json.tool
```

If step 4 shows `chat list not found` rather than `inserted: N`, the pairing didn't stick — re-run step 2.

## Pairing pub account

Same as above but profile path = `/home_ai/data/wa-profiles/pub`, and the QR scan happens on the pub phone (not your personal one).

## Pairing without a display (alternative)

If running headless-only (no X11 available):

```bash
# Run the pair container with VNC exposed
docker run --rm -p 5900:5900 \
  -v /home_ai/data/wa-profiles/personal:/profile \
  mcr.microsoft.com/playwright/python:v1.45.0-jammy \
  bash -c "
    apt-get update && apt-get install -y x11vnc xvfb &&
    Xvfb :99 -screen 0 1280x900x24 &
    x11vnc -display :99 -nopw -forever &
    DISPLAY=:99 python3 -c \"
      from playwright.sync_api import sync_playwright; import time;
      with sync_playwright() as p:
          ctx = p.chromium.launch_persistent_context('/profile', headless=False);
          ctx.new_page().goto('https://web.whatsapp.com');
          time.sleep(600)
    \"
"
```

Then VNC into `tailscale-host:5900` from your Mac, scan the QR, close.

## Troubleshooting

- **"Phone not connected"**: phone has been offline > 14 days, or WhatsApp force-logged out. Re-pair.
- **`chat list not found`** during scrape: profile dir empty or pairing didn't stick. Re-run pairing.
- **Sudden ban / disconnection**: WhatsApp detected automation patterns. Throttle harder, send less, switch to WhatsApp Business Cloud API for high-volume use.
