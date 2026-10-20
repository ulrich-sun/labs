variable "region" {
  description = "Région AWS"
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Tag Owner posé sur toutes les ressources"
  type        = string
  default     = "poc-kargo"
}

variable "instance_type" {
  description = "t3.medium (2 vCPU / 4 Go) suffit ; t3.large si les pods sont OOMKilled"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "ssh_public_key_path" {
  description = "Clé publique SSH déposée sur la VM (ex. ~/.ssh/id_ed25519.pub)"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "Seule adresse autorisée en SSH, ex. 203.0.113.10/32 (curl -s https://checkip.amazonaws.com)"
  type        = string
}

variable "allowed_http_cidr" {
  description = "Adresses autorisées sur 80/443 (Gateway). Vide = allowed_ssh_cidr. 0.0.0.0/0 = public, seulement après l'authentification basique d'Argo Workflows (gateway/20-workflows-auth.yaml)"
  type        = string
  default     = null
}

variable "k3s_channel" {
  description = "Canal k3s (stable, latest, ou une version mineure comme v1.33)"
  type        = string
  default     = "stable"
}
