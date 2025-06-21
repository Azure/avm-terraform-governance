variable "location" {
  type        = string
  description = "The Azure location where resources will be created"
  nullable    = false
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Enable telemetry for the module"
  nullable    = false
}
