#!/usr/bin/env bash
# u236-marketing-sweep.sh — mark obvious marketing/junk email as classification='ignored'
#
# Forward-looking companion to the U235 backfill junk pass. Runs hourly over
# recently-received mail so newly-ingested marketing self-filters out of the
# useful-email views. HIGH PRECISION: matches marketing-platform domains,
# marketing subdomains (e./email./news./newsletter./mailer./marketing./send.),
# pure-social senders, promo-only local-parts, and strongly-promotional
# subjects — while PROTECTING operational, family, recruitment, regulatory and
# financial senders (substring guard = deliberately conservative; over-protect
# rather than hide a real email).
#
# Arg 1 = lookback window (default '3 days'). Pass a wider window for a one-off
# catch-up, e.g. `u236-marketing-sweep.sh '60 days'`.
set -euo pipefail
WINDOW="${1:-3 days}"

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<SQL
BEGIN;
SET LOCAL app.current_entity='all';
SET LOCAL app.current_realm='owner';
UPDATE emails SET classification='ignored'
WHERE classification IS DISTINCT FROM 'ignored'
  AND received_at > now() - interval '${WINDOW}'
  AND from_address IS NOT NULL
  AND (
       lower(split_part(from_address,'@',2)) ~ '(facebookmail\.com|mailchimp|sendgrid|klaviyo|brevosend|hubspot|mailerlite|campaign|sparkpost|rsgsv|mcsv|mailgun|sendinblue|cmail|createsend)'
    OR lower(split_part(from_address,'@',2)) ~ '^(e|email|news|newsletter|mailer|marketing|send|enews|email1)\.'
    OR lower(split_part(from_address,'@',2)) IN ('e.linkedin.com','mail.instagram.com','t.youtube.com')
    OR lower(split_part(from_address,'@',1)) IN ('newsletter','uk.newsletter','marketing','promo','promotions','deals','offers','news','friendupdates','mailer-daemon')
    OR subject ~* '(unsubscribe|[0-9]+% off|newsletter|flash sale|shop now|new arrivals|free delivery|limited time|last chance|don''t miss)'
  )
  AND lower(split_part(from_address,'@',2)) !~ '(booking|caterbook|airbnb|hotel-email|collinsbookings|designmynight|xero|dext|tanda|workforce|jrf\.lls|westcountry|forestproduce|staustell|malthousetintagel|gmail|google|dojo|replit|rightmove|tripadvisor|indeed|stjosephscornwall|wadebridgeprimary|kingfisher|caterpay|sumup|barclay|natwest|hsbc|hmrc|gov\.uk|tpr|pension|\.nhs|police|council|companieshouse|fca)';
COMMIT;
SQL
