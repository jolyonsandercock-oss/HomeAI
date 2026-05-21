FROM hashicorp/vault:1.15.6

WORKDIR /etc/vault-agent

COPY agent.hcl /etc/vault-agent/agent.hcl

# role_id + secret_id will be bind-mounted in at runtime from env vars.
# tmpfs volume mounted at /run/secrets is where the templates render.

ENTRYPOINT ["vault"]
CMD ["agent", "-config=/etc/vault-agent/agent.hcl"]
