variable cluster_name {
  type        = string
  default     = ""
  description = "description"
}

variable cluster_endpoint {
  type        = string
  default     = ""
  description = "description"
}

variable cluster_version {
  type        = string
  description = "description"
}

variable cluster_certificate_authority_data {
  type        = string
  description = "description"
}

variable oidc_provider_arn {
  type        = string
  default     = ""
  description = "description"
}

variable region {
  type        = string
  default     = ""
  description = "description"
}

variable account_id {
  type        = string
  default     = ""
  description = "description"
}

variable vpc_id {
  type        = string
  default     = ""
  description = "description"
}

variable "tags" {
  type = map(string)
}

variable subnet_ids {
  type        = list(string)
  description = "description"
}