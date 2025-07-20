variable "prefix" {
  description = "Prefix for resources in AWS."
  default     = "raa"
}

variable "project" {
  description = "Project name for tagging resources"
  default     = "shai@example.com"
}

variable "contact" {
  description = "Contact email for tagging resources."
  default     = "shai@example.com"
}
