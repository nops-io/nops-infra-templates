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
  default     = "1.30"
  description = "description"
}

variable region {
  type        = string
  default     = ""
  description = "description"
}

variable cluster_certificate_authority_data {
  type        = string
  default     = ""
  description = "description"
}

variable oidc_provider_arn {
  type        = string
  default     = ""
  description = "description"
}

variable subnet_ids {
  type        = list(string)
  default     = [ "" ]
  description = "description"
}
