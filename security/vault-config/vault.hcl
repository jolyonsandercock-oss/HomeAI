storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address                       = "0.0.0.0:8200"
  tls_disable                   = true
  telemetry {
    unauthenticated_metrics_access = true
  }
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}

api_addr = "http://0.0.0.0:8200"
ui = true
disable_mlock = true
