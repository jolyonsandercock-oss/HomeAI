#!/usr/bin/env python3
"""Create auto-rule function and trigger + daily auto-classify cron."""

import subprocess

# SQL to run via docker exec
sql = """
-- 1. Function: auto-create vendor_category_rule from feedback
CREATE OR REPLACE FUNCTION auto_create_vendor_rule_from_feedback()
RETURNS trigger AS $$
BEGIN
  -- Only auto-create rules for manual feedback with a corrected category
  IF NEW.source = 'manual' AND NEW.corrected_category IS NOT NULL AND NEW.corrected_category != '' THEN
    
    -- Check if a rule already exists for this vendor_domain
    IF NOT EXISTS (
      SELECT 1 FROM vendor_category_rules 
      WHERE domain_pattern = split_part(NEW.vendor_domain, '@', 2)  -- extract domain from email
         OR domain_pattern = NEW.vendor_domain
    ) THEN
      -- Create a new rule
      INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, notes, site)
      VALUES (
        split_part(NEW.vendor_domain, '@', 2),  -- domain from email address
        NEW.corrected_category,
        NEW.vendor_domain,
        50,  -- lower priority than explicitly set rules (10), so manual overrides win
        'Auto-created from line_category_feedback #' || NEW.id,
        'shared'
      )
      ON CONFLICT (domain_pattern, site) DO UPDATE 
        SET category = EXCLUDED.category,
            priority = LEAST(vendor_category_rules.priority, 50),
            notes = vendor_category_rules.notes || '; updated by feedback #' || NEW.id;
    END IF;
  END IF;
  
  -- Also auto-assign department on vendor_invoice_lines if corrected_department was provided
  IF NEW.source = 'manual' AND NEW.corrected_department IS NOT NULL THEN
    -- Update the line item's department
    UPDATE vendor_invoice_lines 
    SET department = NEW.corrected_department
    WHERE id = NEW.line_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. Create the trigger on line_category_feedback
DROP TRIGGER IF EXISTS trg_line_category_feedback_auto_rule ON line_category_feedback;
CREATE TRIGGER trg_line_category_feedback_auto_rule
  AFTER INSERT ON line_category_feedback
  FOR EACH ROW
  EXECUTE FUNCTION auto_create_vendor_rule_from_feedback();

-- 3. Also create a trigger on invoice_feedback for vendor-level categorisation
CREATE OR REPLACE FUNCTION auto_create_vendor_rule_from_invoice_feedback()
RETURNS trigger AS $$
DECLARE
  v_vendor_domain TEXT;
  v_vendor_name TEXT;
BEGIN
  IF NEW.applied_at IS NOT NULL AND NEW.ai_proposal IS NOT NULL THEN
    -- Extract vendor domain from the invoice
    SELECT vendor_domain, vendor_name INTO v_vendor_domain, v_vendor_name
    FROM vendor_invoice_inbox WHERE id = NEW.invoice_id;
    
    -- If AI proposal has a category, create rule if none exists
    IF NEW.ai_proposal ? 'category' AND NOT EXISTS (
      SELECT 1 FROM vendor_category_rules 
      WHERE domain_pattern = split_part(v_vendor_domain, '@', 2)
    ) THEN
      INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, notes, site)
      VALUES (
        split_part(v_vendor_domain, '@', 2),
        NEW.ai_proposal->>'category',
        v_vendor_name,
        60,
        'Auto-created from invoice_feedback #' || NEW.id,
        'shared'
      )
      ON CONFLICT (domain_pattern, site) DO NOTHING;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_invoice_feedback_auto_rule ON invoice_feedback;
CREATE TRIGGER trg_invoice_feedback_auto_rule
  AFTER UPDATE OF applied_at ON invoice_feedback
  FOR EACH ROW
  WHEN (NEW.applied_at IS NOT NULL AND OLD.applied_at IS NULL)
  EXECUTE FUNCTION auto_create_vendor_rule_from_invoice_feedback();
"""

result = subprocess.run(
    ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai", "-c", sql],
    capture_output=True, text=True, cwd="/home_ai"
)
print("STDOUT:", result.stdout)
print("STDERR:", result.stderr[:500] if result.stderr else "")
print("Exit:", result.returncode)
