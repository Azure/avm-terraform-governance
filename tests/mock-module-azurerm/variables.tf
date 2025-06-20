variable "enable_telemetry" {
  description = "Enable telemetry for the module"
  type        = bool
  default     = true
  nullable    = false
}

variable "location" {
  description = "The Azure location where resources will be created"
  type        = string
  nullable    = false
}
