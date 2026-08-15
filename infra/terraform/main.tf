# DNS only.
#
# The droplet, firewall and the tasks record are owned by the weektasks repo's
# terraform state. This app is a second vhost on that same host, so the only
# thing there is to manage here is one A record. Keeping it in a separate state
# means neither repo can accidentally plan a change to the other's resources.
#
#   export DIGITALOCEAN_TOKEN=...
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

variable "do_token" {
  type        = string
  description = "DigitalOcean API token. Leave null and export DIGITALOCEAN_TOKEN instead."
  sensitive   = true
  default     = null
}

variable "domain" {
  type        = string
  description = "Existing DO-managed zone. Note the plural: bob-productions.dev."
  default     = "bob-productions.dev"
}

variable "subdomain" {
  type        = string
  description = "Subdomain record for this app."
  default     = "icb"
}

variable "droplet_ipv4" {
  type        = string
  description = "The weektasks droplet this app is hosted on (weektasks-lon1-01)."
  default     = "161.35.37.2"
}

# Referenced, not managed: the zone and its other records (api, tasks) belong to
# other things and must stay untouched.
data "digitalocean_domain" "root" {
  name = var.domain
}

resource "digitalocean_record" "icb" {
  domain = data.digitalocean_domain.root.name
  type   = "A"
  name   = var.subdomain
  value  = var.droplet_ipv4
  ttl    = 3600
}

output "fqdn" {
  value = "${var.subdomain}.${var.domain}"
}
