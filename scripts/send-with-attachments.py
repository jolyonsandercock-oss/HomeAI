#!/usr/bin/env python3
# send-with-attachments.py — fills the google-fetch attachment-send gap
# (the /send/{account} endpoint builds multipart/alternative only, no files).
# Run INSIDE homeai-google-fetch so it reuses find_account/access_token.
#   docker cp this + the files into the container, then:
#   docker exec homeai-google-fetch python3 /tmp/send-with-attachments.py \
#       <account> <to> <subject> <body_file|-> <attach1> [attach2 ...]
import sys, asyncio, base64, mimetypes, os, httpx
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication
import main  # the google-fetch FastAPI module (find_account, access_token)


async def go(account, to, subject, body_file, attachments):
    acc = await main.find_account(account)
    tok = await main.access_token(acc)
    body = ""
    if body_file and body_file != "-" and os.path.exists(body_file):
        body = open(body_file, encoding="utf-8", errors="replace").read()
    msg = MIMEMultipart("mixed")
    msg["From"] = acc["email"]
    msg["To"] = to
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain", "utf-8"))
    for path in attachments:
        ctype, _ = mimetypes.guess_type(path)
        subtype = (ctype or "application/octet-stream").split("/", 1)[-1]
        with open(path, "rb") as f:
            part = MIMEApplication(f.read(), _subtype=subtype)
        part.add_header("Content-Disposition", "attachment", filename=os.path.basename(path))
        msg.attach(part)
    raw = base64.urlsafe_b64encode(msg.as_bytes()).rstrip(b"=").decode("ascii")
    async with httpx.AsyncClient(timeout=90) as c:
        r = await c.post("https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
                         headers={"Authorization": f"Bearer {tok}"}, json={"raw": raw})
    print(r.status_code, r.text[:300])
    return 0 if r.status_code == 200 else 1


if __name__ == "__main__":
    account, to, subject, body_file = sys.argv[1:5]
    sys.exit(asyncio.run(go(account, to, subject, body_file, sys.argv[5:])))
