-- V277: normalise Expedia ratings into the existing /5 convention so blended averages
-- are meaningful. Expedia is stored on the /10 scale (like booking_com); the review slugs
-- already fold booking_com /10 → /5 via `rating/2.0`. This extends that exact pattern to
-- expedia, and adds expedia to the blended "ALL sources" rollup + source list in the summary.
-- Idempotent: each replace() only fires while the pre-change substring is still present.

-- 1. Per-row + spark + summary normalisation CASE: booking_com → booking_com + expedia.
UPDATE query_whitelist
   SET sql_template = replace(sql_template,
         $o$source = 'booking_com'$o$,
         $n$source IN ('booking_com','expedia')$n$)
 WHERE slug IN ('reviews_filterable_table','reviews_rating_spark_30d','reviews_three_source_summary')
   AND position($o$source = 'booking_com'$o$ IN sql_template) > 0;

-- 2. Blended "ALL sources" rollup in the summary must include expedia.
UPDATE query_whitelist
   SET sql_template = replace(sql_template,
         $o$source IN ('google','tripadvisor','booking_com')$o$,
         $n$source IN ('google','tripadvisor','booking_com','expedia')$n$)
 WHERE slug = 'reviews_three_source_summary';

-- 3. Give Expedia its own per-source row in the summary's source list.
UPDATE query_whitelist
   SET sql_template = replace(sql_template,
         $o$('booking_com','Booking.com'))$o$,
         $n$('booking_com','Booking.com'),('expedia','Expedia'))$n$)
 WHERE slug = 'reviews_three_source_summary';
