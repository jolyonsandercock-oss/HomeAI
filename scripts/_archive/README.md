# Archive

Scripts that were partial / parallel / superseded designs. Kept for
forensic reference but not loaded by anything.

- **u67-paperless-smb-bootstrap.sh** — Earlier Samba bootstrap draft that
  pre-dated U73. Superseded by u73-format-hd.sh + u73-setup-samba.sh +
  u73b-smb1-for-brother.sh which work end-to-end.

- **u73-install-ocr.sh / u73-ocr-watcher.sh / u73-ocr-watcher.service** —
  Alternative OCR design: inotify-watch the SMB inbox and run ocrmypdf
  in-place. Rejected because Paperless already does OCR (Tesseract by
  default), runs as a managed container, has its own task queue, and our
  webhook integration is in place. Re-revisit only if Paperless OCR ever
  becomes the bottleneck — at that point ocrmypdf-as-preprocess might be
  worth wiring in front of Paperless's consume folder, but it's not
  needed today.
