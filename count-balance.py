#!/usr/bin/env python3
"""Count bracket balance before return."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

idx = content.find("return (")
pre = content[:idx]

opens = pre.count("{") + pre.count("(") + pre.count("[")
closes = pre.count("}") + pre.count(")") + pre.count("]")
print(f"Before return: opens={opens} closes={closes} diff={opens-closes}")

# Now check WHOLE file
opens_t = content.count("{") + content.count("(") + content.count("[")
closes_t = content.count("}") + content.count(")") + content.count("]")
print(f"Full file: opens={opens_t} closes={closes_t} diff={opens_t-closes_t}")
